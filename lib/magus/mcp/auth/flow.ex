defmodule Magus.MCP.Auth.Flow do
  @moduledoc """
  OAuth 2.1 flow orchestration for connecting Magus (an MCP *client*) to a remote
  MCP server on behalf of a single user.

  This is the thin layer that ties together the pieces built in the earlier
  Phase 4 tasks and drives the `oidcc` library:

    * `Magus.MCP.Auth.Discovery.ensure_metadata/2` (Task 1) — cached OAuth
      endpoints for the server.
    * `Magus.MCP.Auth.State.issue/2` (Task 2) — the HMAC-bound `state` + the
      server-side PKCE verifier.
    * `oidcc` (3.7.2) ad-hoc, worker-free path — build a `%Oidcc.ProviderConfiguration{}`
      + `Oidcc.ClientContext.from_manual/4` per request, then
      `Oidcc.Authorization.create_redirect_url/2` (authorize) and
      `Oidcc.Token.retrieve/3` (code exchange). Refresh does NOT use oidcc — see
      `refresh/2` for why (oidcc's refresh is OIDC-coupled and rejects the
      id-token-less responses MCP servers return).
    * The per-user `Magus.MCP.ServerCredential.oauth_client` — the client identity
      (DCR-registered or manually configured), reused across authorize + exchange.

  ## Public functions

    * `authorize_url/3` — called by the controller on flow start. Resolves the
      client identity (DCR-registering + persisting if needed), issues a `state`
      + PKCE verifier, and builds the authorize redirect URL.
    * `exchange_code/5` — called by the controller on callback. Exchanges the auth
      code for tokens and RETURNS them (does not persist — the controller does).
    * `refresh/2` — called by the executor. Refreshes an access token from a
      stored refresh token, rotation-aware, and RETURNS the new tokens (does not
      persist — the executor does).

  Every function returns `{:ok, _} | {:error, reason}` and never raises into the
  caller. Named reasons `:client_id_required` (authorize) and `:invalid_grant`
  (refresh) are distinguished; other oidcc failures collapse to
  `{:error, {:oauth_error, detail}}` — sanitized so no token/secret ever leaks
  into an error term or log.

  ## RFC 8707 resource indicator

  The `resource` parameter audience-binds the issued token to this MCP server. We
  use the RFC 9728 canonical `resource` identifier from the protected-resource
  metadata when present, else fall back to `server.url`.

  ## SSRF

  The specific endpoint each function is about to hit (authorize / token /
  registration) is re-validated with `Magus.MCP.SafeUrl.validate/1` immediately
  before the oidcc call, even though discovery already validated it — the cached
  metadata could be stale and this is cheap defense-in-depth.
  """

  alias Magus.MCP
  alias Magus.MCP.Auth.Discovery
  alias Magus.MCP.Auth.State
  alias Magus.MCP.SafeUrl

  # Default scopes if the AS advertises none. "openid" is harmless for OAuth-only
  # servers and keeps oidcc's scope handling happy.
  @default_scopes ["openid"]

  @type tokens :: %{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          expires_at: DateTime.t() | nil
        }

  # ---------------------------------------------------------------------------
  # authorize_url
  # ---------------------------------------------------------------------------

  @doc """
  Builds the authorization-redirect URL to start the OAuth flow for `user` against
  `server`, sending them to `redirect_uri` after consent.

  Ensures metadata, resolves the client identity (using a stored `oauth_client`,
  else DCR-registering against the AS registration endpoint and persisting the
  result, else `{:error, :client_id_required}`), issues a `state` + PKCE verifier,
  and builds the URL with the S256 challenge, scopes, and the RFC 8707 `resource`
  indicator. The authorize endpoint is SSRF-validated before use.
  """
  @spec authorize_url(MCP.Server.t(), struct(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def authorize_url(%MCP.Server{} = server, user, redirect_uri) when is_binary(redirect_uri) do
    with {:ok, metadata} <- Discovery.ensure_metadata(server, user),
         {:ok, client} <- resolve_or_register_client(server, user, metadata, redirect_uri),
         authorize_endpoint = metadata["authorization_endpoint"],
         :ok <- safe(authorize_endpoint),
         {:ok, ctx} <- build_client_context(metadata, client) do
      {state, verifier} = State.issue(server.id, user.id)

      opts = %{
        redirect_uri: redirect_uri,
        scopes: scopes(metadata),
        state: state,
        pkce_verifier: verifier,
        url_extension: [{"resource", resource_uri(server, metadata)}]
      }

      case Oidcc.Authorization.create_redirect_url(ctx, opts) do
        {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
        {:error, reason} -> {:error, {:oauth_error, sanitize(reason)}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # exchange_code
  # ---------------------------------------------------------------------------

  @doc """
  Exchanges an authorization `code` for tokens and returns them.

  Uses the previously-persisted `oauth_client` (it must exist — `authorize_url/3`
  persists it), the PKCE `verifier` recovered from the `state`, and the original
  `redirect_uri`. The token endpoint is SSRF-validated before use. Returns
  `{:ok, %{access_token, refresh_token, expires_at}}`; does NOT persist (the
  controller persists via `MCP.store_oauth_tokens`).
  """
  @spec exchange_code(MCP.Server.t(), struct(), String.t(), String.t(), String.t()) ::
          {:ok, tokens()} | {:error, term()}
  def exchange_code(%MCP.Server{} = server, user, code, verifier, redirect_uri)
      when is_binary(code) and is_binary(verifier) and is_binary(redirect_uri) do
    with {:ok, metadata} <- Discovery.ensure_metadata(server, user),
         {:ok, client} <- load_stored_client(server, user),
         token_endpoint = metadata["token_endpoint"],
         :ok <- safe(token_endpoint),
         {:ok, ctx} <- build_client_context(metadata, client) do
      opts = %{
        redirect_uri: redirect_uri,
        pkce_verifier: verifier,
        body_extension: [{"resource", resource_uri(server, metadata)}]
      }

      case Oidcc.Token.retrieve(code, ctx, opts) do
        {:ok, token} -> {:ok, to_token_map(token, nil)}
        {:error, reason} -> {:error, classify_token_error(reason)}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # refresh
  # ---------------------------------------------------------------------------

  @doc """
  Refreshes an access token from the refresh token stored on `user_credential`.

  Rotation-aware: if the AS omits a new refresh token, the previously-stored one
  is carried forward (never nilled). The token endpoint is SSRF-validated before
  use. Surfaces `{:error, :invalid_grant}` distinctly for an expired/revoked
  refresh token. Returns the new tokens; does NOT persist (the executor persists
  via `MCP.refresh_oauth_tokens`).

  ## Why not `Oidcc.Token.refresh/3`?

  oidcc's `refresh/3` is OIDC-coupled: after the refresh it unconditionally
  requires the response to carry an id_token whose `sub` matches the original
  (`oidcc_token.erl` ~lines 528, 561-563), returning `{:error, :sub_invalid}`
  otherwise — even with `expected_subject: :any`. MCP servers are OAuth 2.1
  resource servers, not OIDC providers, so they do not issue id_tokens on
  refresh; oidcc would therefore fail every MCP refresh. We instead issue the
  standard RFC 6749 §6 `grant_type=refresh_token` POST directly (the same shape
  oidcc would build), keeping the SSRF gate and the RFC 8707 `resource` body
  param. authorize + exchange still go through oidcc (they work for OAuth-only
  servers — a missing id_token there is benign).
  """
  @spec refresh(MCP.Server.t(), MCP.ServerCredential.t()) ::
          {:ok, tokens()} | {:error, :invalid_grant | term()}
  def refresh(%MCP.Server{} = server, %MCP.ServerCredential{} = user_credential) do
    with {:ok, metadata} <- ensure_metadata_for_refresh(server, user_credential),
         {:ok, client} <- client_from_credential(user_credential),
         {:ok, refresh_token} <- stored_refresh_token(user_credential),
         token_endpoint = metadata["token_endpoint"],
         :ok <- safe(token_endpoint) do
      post_refresh(token_endpoint, refresh_token, client, resource_uri(server, metadata))
    end
  end

  # ---------------------------------------------------------------------------
  # Client identity resolution
  # ---------------------------------------------------------------------------

  # authorize_url: use a stored client, else DCR, else :client_id_required.
  defp resolve_or_register_client(server, user, metadata, redirect_uri) do
    case stored_client(server, user) do
      {:ok, %{} = client} ->
        {:ok, client}

      {:ok, nil} ->
        register_client(server, user, metadata, redirect_uri)

      {:error, _} = err ->
        err
    end
  end

  # DCR: only if the AS advertises a registration endpoint; SSRF it first, then
  # register via oidcc and persist the client_id/secret on the credential so the
  # callback's token exchange reuses the same client.
  defp register_client(server, user, metadata, redirect_uri) do
    case metadata["registration_endpoint"] do
      endpoint when is_binary(endpoint) and endpoint != "" ->
        with :ok <- safe(endpoint),
             {:ok, provider_config} <- provider_configuration(metadata),
             {:ok, response} <- do_register(provider_config, redirect_uri),
             {:ok, client} <- persist_registered_client(server, user, response) do
          {:ok, client}
        end

      _ ->
        {:error, :client_id_required}
    end
  end

  defp do_register(provider_config, redirect_uri) do
    registration = %Oidcc.ClientRegistration{
      redirect_uris: [redirect_uri],
      grant_types: ["authorization_code", "refresh_token"],
      token_endpoint_auth_method: "none"
    }

    case Oidcc.ClientRegistration.register(provider_config, registration) do
      {:ok, %Oidcc.ClientRegistration.Response{} = response} -> {:ok, response}
      {:error, reason} -> {:error, {:oauth_error, sanitize(reason)}}
    end
  end

  # Persist the DCR result. client_secret is :undefined for public clients; store
  # only present values. The map is string-keyed (jsonb-friendly under the
  # EncryptedMap column).
  defp persist_registered_client(server, user, %Oidcc.ClientRegistration.Response{} = response) do
    client =
      %{"client_id" => response.client_id}
      |> put_if_binary("client_secret", response.client_secret)
      |> put_if_binary("registration_access_token", response.registration_access_token)
      |> put_if_binary("registration_client_uri", response.registration_client_uri)

    case MCP.store_oauth_client(
           %{mcp_server_id: server.id, oauth_client: client},
           actor: user
         ) do
      {:ok, _credential} -> {:ok, client}
      {:error, reason} -> {:error, {:client_persist_failed, sanitize(reason)}}
    end
  end

  defp put_if_binary(map, key, value) when is_binary(value) and value != "",
    do: Map.put(map, key, value)

  defp put_if_binary(map, _key, _value), do: map

  # Read the stored per-user credential and return its oauth_client (or nil).
  defp stored_client(server, user) do
    case MCP.get_credential_for_server(server.id, actor: user) do
      {:ok, %MCP.ServerCredential{oauth_client: client}} when is_map(client) and client != %{} ->
        {:ok, client}

      {:ok, _} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, {:credential_read_failed, sanitize(reason)}}
    end
  end

  # exchange_code: the client MUST exist by now (authorize_url persisted it).
  defp load_stored_client(server, user) do
    case stored_client(server, user) do
      {:ok, %{} = client} -> {:ok, client}
      {:ok, nil} -> {:error, :client_id_required}
      {:error, _} = err -> err
    end
  end

  # refresh: the client lives on the already-loaded credential.
  defp client_from_credential(%MCP.ServerCredential{oauth_client: client})
       when is_map(client) and client != %{},
       do: {:ok, client}

  defp client_from_credential(_credential), do: {:error, :client_id_required}

  defp stored_refresh_token(%MCP.ServerCredential{oauth_tokens: tokens}) when is_map(tokens) do
    case Map.get(tokens, "refresh_token") do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :no_refresh_token}
    end
  end

  defp stored_refresh_token(_credential), do: {:error, :no_refresh_token}

  # ---------------------------------------------------------------------------
  # RFC 6749 §6 refresh (direct, not oidcc — see refresh/2 doc)
  # ---------------------------------------------------------------------------

  # Conservative per-request budget for the token-endpoint POST.
  @refresh_timeout 10_000

  defp post_refresh(token_endpoint, refresh_token, client, resource_uri) do
    form =
      [
        {"grant_type", "refresh_token"},
        {"refresh_token", refresh_token},
        # RFC 8707 audience binding for the refreshed token.
        {"resource", resource_uri}
      ]
      |> add_public_client_id(client)

    case post_token(token_endpoint, form, client) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        parse_refresh_response(body, refresh_token)

      {:ok, %Req.Response{status: 400, body: body}} ->
        if oauth_error(body) == "invalid_grant" do
          {:error, :invalid_grant}
        else
          {:error, {:oauth_error, {:http_error, 400}}}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, {:oauth_error, {:http_error, status}}}

      {:error, _reason} ->
        # Never surface the raw transport error (could echo the URL/headers).
        {:error, {:oauth_error, :refresh_request_failed}}
    end
  end

  # Public clients (DCR with no secret, token_endpoint_auth_method "none") MUST
  # send client_id in the body per RFC 6749 §3.2.1; confidential clients use
  # HTTP Basic instead (added in post_token/3).
  defp add_public_client_id(form, client) do
    case client_secret(client) do
      :unauthenticated -> form ++ [{"client_id", client["client_id"]}]
      _secret -> form
    end
  end

  defp post_token(token_endpoint, form, client) do
    opts =
      [
        form: form,
        receive_timeout: @refresh_timeout,
        retry: false
      ]
      |> maybe_basic_auth(client)

    Req.post(token_endpoint, opts)
  rescue
    # Never interpolate the exception: its message can echo the request body
    # (refresh_token) or Basic-auth header (client_secret). Reuse the same
    # opaque tag as the transport-error branch in refresh/3 so the caller's
    # {:error, _reason} clause normalizes both identically.
    _error -> {:error, {:oauth_error, :refresh_request_failed}}
  end

  defp maybe_basic_auth(opts, client) do
    case client_secret(client) do
      :unauthenticated -> opts
      secret -> Keyword.put(opts, :auth, {:basic, "#{client["client_id"]}:#{secret}"})
    end
  end

  # Parse a JSON token response (Req auto-decodes a map; tolerate a binary body
  # too). Carry the old refresh token forward when the AS omits rotation.
  defp parse_refresh_response(body, old_refresh) when is_map(body) do
    case body["access_token"] do
      access when is_binary(access) and access != "" ->
        {:ok,
         %{
           access_token: access,
           refresh_token: new_refresh(body["refresh_token"], old_refresh),
           expires_at: expires_at_from_seconds(body["expires_in"])
         }}

      _ ->
        {:error, {:oauth_error, :no_access_token}}
    end
  end

  defp parse_refresh_response(body, old_refresh) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> parse_refresh_response(map, old_refresh)
      _ -> {:error, {:oauth_error, :invalid_token_response}}
    end
  end

  defp parse_refresh_response(_body, _old), do: {:error, {:oauth_error, :invalid_token_response}}

  # Rotation: keep the AS-issued refresh token if present, else carry the stored
  # one forward (never nil).
  defp new_refresh(new, _old) when is_binary(new) and new != "", do: new
  defp new_refresh(_new, old), do: old

  defp expires_at_from_seconds(seconds) when is_integer(seconds),
    do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp expires_at_from_seconds(seconds) when is_binary(seconds) do
    case Integer.parse(seconds) do
      {n, ""} -> DateTime.add(DateTime.utc_now(), n, :second)
      _ -> nil
    end
  end

  defp expires_at_from_seconds(_seconds), do: nil

  defp oauth_error(body) when is_map(body), do: body["error"]

  defp oauth_error(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => err}} -> err
      _ -> nil
    end
  end

  defp oauth_error(_body), do: nil

  # ---------------------------------------------------------------------------
  # oidcc construction
  # ---------------------------------------------------------------------------

  # Build the ad-hoc client context (no worker) from the discovered metadata and
  # the resolved client identity.
  defp build_client_context(metadata, client) do
    with {:ok, provider_config} <- provider_configuration(metadata) do
      client_id = client["client_id"]
      client_secret = client_secret(client)

      ctx =
        Oidcc.ClientContext.from_manual(provider_config, empty_jwks(), client_id, client_secret)

      {:ok, ctx}
    end
  end

  # A confidential client has a stored secret; a public client (DCR with no
  # secret) authenticates with no secret via :unauthenticated.
  defp client_secret(%{"client_secret" => secret}) when is_binary(secret) and secret != "",
    do: secret

  defp client_secret(_client), do: :unauthenticated

  # Build the %Oidcc.ProviderConfiguration{} struct DIRECTLY from the discovered
  # RFC 8414 metadata (the smoke-test path), rather than oidcc's
  # decode_configuration which requires OIDC-only fields an OAuth-AS may omit.
  # `code_challenge_methods_supported: ["S256"]` is forced present so PKCE does
  # not silently degrade to plain or get omitted.
  defp provider_configuration(metadata) do
    issuer = metadata["issuer"]
    authorize = metadata["authorization_endpoint"]
    token = metadata["token_endpoint"]

    if is_binary(issuer) and is_binary(authorize) and is_binary(token) do
      config = %Oidcc.ProviderConfiguration{
        issuer: issuer,
        authorization_endpoint: authorize,
        token_endpoint: token,
        registration_endpoint: metadata["registration_endpoint"] || :undefined,
        jwks_uri: metadata["jwks_uri"] || "#{issuer}/.well-known/jwks.json",
        scopes_supported: scopes(metadata),
        response_types_supported: ["code"],
        response_modes_supported: ["query"],
        grant_types_supported: ["authorization_code", "refresh_token"],
        subject_types_supported: [:public],
        id_token_signing_alg_values_supported: ["RS256"],
        token_endpoint_auth_methods_supported: ["none", "client_secret_basic"],
        code_challenge_methods_supported: ["S256"],
        # Booleans the record requires non-nil.
        claims_parameter_supported: false,
        request_parameter_supported: false,
        request_uri_parameter_supported: false,
        require_request_uri_registration: false,
        require_pushed_authorization_requests: false,
        authorization_response_iss_parameter_supported: false,
        require_signed_request_object: false,
        tls_client_certificate_bound_access_tokens: false,
        claim_types_supported: [:normal],
        revocation_endpoint_auth_methods_supported: ["client_secret_basic"],
        introspection_endpoint_auth_methods_supported: ["client_secret_basic"],
        mtls_endpoint_aliases: %{},
        extra_fields: %{}
      }

      {:ok, config}
    else
      {:error, :incomplete_metadata}
    end
  end

  # OAuth-only servers have no ID token to verify; from_manual/4 only requires a
  # %JOSE.JWK{} struct, so an empty key set is sufficient.
  defp empty_jwks, do: JOSE.JWK.from(%{"keys" => []})

  defp scopes(metadata) do
    case metadata["scopes_supported"] do
      [_ | _] = list -> Enum.filter(list, &is_binary/1)
      _ -> @default_scopes
    end
  end

  defp resource_uri(%MCP.Server{url: url}, metadata) do
    case metadata["resource"] do
      resource when is_binary(resource) and resource != "" -> resource
      _ -> url
    end
  end

  # ---------------------------------------------------------------------------
  # Token mapping + error classification
  # ---------------------------------------------------------------------------

  # Turn an %Oidcc.Token{} into the caller-facing map. `fallback_refresh` is the
  # previously-stored refresh token, carried forward when the AS omits rotation
  # (refresh struct is :none / nil). Never overwrite a stored token with nil.
  defp to_token_map(%Oidcc.Token{} = token, fallback_refresh) do
    %{
      access_token: access_token(token),
      refresh_token: refresh_token(token) || fallback_refresh,
      expires_at: expires_at(token)
    }
  end

  defp access_token(%Oidcc.Token{access: %Oidcc.Token.Access{token: token}})
       when is_binary(token),
       do: token

  defp access_token(_token), do: nil

  defp refresh_token(%Oidcc.Token{refresh: %Oidcc.Token.Refresh{token: token}})
       when is_binary(token),
       do: token

  defp refresh_token(_token), do: nil

  # `token.access.expires` holds the raw `expires_in` SECONDS (oidcc stores the
  # value as-is; see oidcc_token.erl extract_expiry/extract_access_token).
  # Convert to an absolute instant.
  defp expires_at(%Oidcc.Token{access: %Oidcc.Token.Access{expires: expires_in}})
       when is_integer(expires_in),
       do: DateTime.add(DateTime.utc_now(), expires_in, :second)

  defp expires_at(_token), do: nil

  # An RFC 6749 token error response is a 400 with `{"error": "invalid_grant"}`.
  # oidcc surfaces a non-2xx JSON body as `{:http_error, status, decoded_map}`
  # (string keys, via jose:decode). Map invalid_grant distinctly; everything else
  # is a sanitized opaque oauth error.
  defp classify_token_error({:http_error, _status, %{"error" => "invalid_grant"}}),
    do: :invalid_grant

  defp classify_token_error(reason), do: {:oauth_error, sanitize(reason)}

  # ---------------------------------------------------------------------------
  # Metadata + SSRF helpers
  # ---------------------------------------------------------------------------

  # The server passed to refresh/2 carries its cached oauth_metadata; use it if
  # present, else re-discover (a stale reload could have dropped it). Discovery
  # needs an actor; the credential's owning user is that actor.
  defp ensure_metadata_for_refresh(%MCP.Server{oauth_metadata: cached}, _credential)
       when is_map(cached) and map_size(cached) > 0,
       do: {:ok, cached}

  defp ensure_metadata_for_refresh(server, credential),
    do: Discovery.ensure_metadata(server, credential.user)

  defp safe(url) when is_binary(url) do
    case SafeUrl.validate(url) do
      :ok -> :ok
      {:error, reason} -> {:error, {:unsafe_endpoint_url, reason}}
    end
  end

  defp safe(_url), do: {:error, :missing_endpoint}

  # Reduce an oidcc/Ash error term to a non-secret summary. Token-exchange and
  # refresh errors can carry the AS response body (which for an error is just an
  # `{"error": ...}` descriptor, no token), but to be safe we only surface a tag.
  defp sanitize({:http_error, status, body}) when is_map(body),
    do: {:http_error, status, Map.take(body, ["error", "error_description"])}

  defp sanitize({:http_error, status, _body}), do: {:http_error, status}
  defp sanitize(reason) when is_atom(reason), do: reason
  defp sanitize({tag, _detail}) when is_atom(tag), do: tag
  defp sanitize(_reason), do: :oauth_request_failed
end
