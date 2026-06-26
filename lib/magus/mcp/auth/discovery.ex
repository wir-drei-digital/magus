defmodule Magus.MCP.Auth.Discovery do
  @moduledoc """
  OAuth 2.1 endpoint discovery for an MCP server (the client-side discovery the
  authorize/token flow needs before it can run).

  Magus is an MCP *client*. Before we can OAuth-connect to a remote MCP server we
  must learn that server's OAuth endpoints. This module performs the two-step
  discovery the MCP auth spec layers on top of OAuth:

    1. **RFC 9728 protected-resource metadata** — fetch
       `<server>/.well-known/oauth-protected-resource`. It names the
       `authorization_servers` (issuer base URLs) that issue tokens for the
       resource, plus the canonical `resource` identifier.

    2. **RFC 8414 / OIDC authorization-server metadata** — for the first listed
       authorization server, fetch `<issuer>/.well-known/oauth-authorization-server`
       (RFC 8414). If that is absent, fall back to OIDC discovery at
       `<issuer>/.well-known/openid-configuration` (parsed through oidcc's
       no-network `Oidcc.ProviderConfiguration.decode_configuration/1`).

  The extracted, non-secret result is cached on `Server.oauth_metadata`. The
  later flow tasks (authorize-URL builder, token exchange, the controller) read
  this cache; this module produces only the normalized map.

  ## SSRF

  EVERY server-controlled URL is passed through `Magus.MCP.SafeUrl.validate/1`
  before it is fetched: the protected-resource URL, the authorization-server
  metadata URL, and the endpoint URLs discovered inside those documents. A bad
  URL anywhere aborts discovery with `{:error, _}` and caches nothing — we never
  persist a partial/junk result.

  ## Normalized metadata shape

  `ensure_metadata/2` returns (and caches) a string-keyed map:

      %{
        "issuer" => "https://as.example.com",
        "authorization_endpoint" => "https://as.example.com/authorize",
        "token_endpoint" => "https://as.example.com/token",
        # nil when the AS does not advertise dynamic client registration:
        "registration_endpoint" => "https://as.example.com/register" | nil,
        "scopes_supported" => ["openid", "mcp", ...],
        "code_challenge_methods_supported" => ["S256"] | nil,
        # RFC 9728 provenance (the resource identifier + the AS list we chose from):
        "resource" => "https://mcp.example.com" | nil,
        "authorization_servers" => ["https://as.example.com", ...]
      }

  String keys throughout so the value round-trips cleanly through the
  `Server.oauth_metadata` jsonb column without atom churn.
  """

  require Logger

  alias Magus.MCP
  alias Magus.MCP.SafeUrl

  @protected_resource_path "/.well-known/oauth-protected-resource"
  @as_metadata_path "/.well-known/oauth-authorization-server"
  @oidc_path "/.well-known/openid-configuration"

  # Conservative per-request budget; discovery talks to a third-party server.
  @receive_timeout 10_000
  # OAuth metadata documents are tiny; cap the body to defend against a hostile
  # server streaming an unbounded response.
  @max_body_bytes 256 * 1024

  @type metadata :: %{optional(String.t()) => term()}

  @doc """
  Returns the server's OAuth discovery metadata, fetching + caching it on first
  use.

  If `Server.oauth_metadata` is already populated, returns it without any HTTP
  (idempotent, cheap re-entry for the flow). Otherwise it runs the RFC 9728 ->
  RFC 8414/OIDC discovery, persists the normalized map via
  `MCP.cache_server_oauth_metadata/3` (actor-scoped), and returns it.

  On any failure (HTTP error, malformed document, or an SSRF-rejected URL inside
  the discovered metadata) returns `{:error, reason}` and caches nothing.
  """
  @spec ensure_metadata(MCP.Server.t(), struct()) :: {:ok, metadata()} | {:error, term()}
  def ensure_metadata(%MCP.Server{oauth_metadata: cached}, _actor)
      when is_map(cached) and map_size(cached) > 0 do
    {:ok, cached}
  end

  def ensure_metadata(%MCP.Server{} = server, actor) do
    with {:ok, metadata} <- discover(server) do
      cache(server, metadata, actor)
    end
  end

  # ---------------------------------------------------------------------------
  # Discovery pipeline
  # ---------------------------------------------------------------------------

  defp discover(%MCP.Server{url: base_url}) do
    with {:ok, pr_doc} <- fetch_json(join(base_url, @protected_resource_path)),
         {:ok, issuer} <- pick_authorization_server(pr_doc),
         {:ok, as_doc} <- fetch_as_metadata(issuer) do
      normalize(as_doc, pr_doc)
    end
  end

  # RFC 9728: the protected-resource doc lists the authorization servers. We take
  # the first one. SafeUrl-validate it (it is server-controlled) before it ever
  # becomes a fetch target.
  defp pick_authorization_server(%{"authorization_servers" => [issuer | _]})
       when is_binary(issuer) do
    case SafeUrl.validate(issuer) do
      :ok -> {:ok, String.trim_trailing(issuer, "/")}
      {:error, reason} -> {:error, {:unsafe_authorization_server_url, reason}}
    end
  end

  defp pick_authorization_server(_doc),
    do: {:error, :no_authorization_servers}

  # RFC 8414 first; fall back to OIDC discovery if the AS does not publish it.
  defp fetch_as_metadata(issuer) do
    case fetch_json(join(issuer, @as_metadata_path)) do
      {:ok, doc} ->
        {:ok, doc}

      {:error, _} ->
        # OIDC fallback: parse through oidcc's no-network decoder, then hand the
        # raw doc back (normalize/2 reads the same RFC-8414/OIDC field names from
        # the raw map). decode_configuration validates the OIDC-required shape.
        with {:ok, oidc_doc} <- fetch_json(join(issuer, @oidc_path)),
             {:ok, _struct} <- decode_oidc(oidc_doc) do
          {:ok, oidc_doc}
        end
    end
  end

  # Route the OIDC document through oidcc's documented no-network parse so we
  # exercise the library's validation (it requires the OIDC-mandatory fields).
  # We keep our own normalized map shape rather than threading the struct out.
  defp decode_oidc(doc) do
    case Oidcc.ProviderConfiguration.decode_configuration(doc) do
      {:ok, %Oidcc.ProviderConfiguration{}} = ok -> ok
      {:error, reason} -> {:error, {:invalid_oidc_configuration, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Normalization (+ SSRF on every discovered endpoint URL)
  # ---------------------------------------------------------------------------

  defp normalize(as_doc, pr_doc) do
    with {:ok, issuer} <- required_string(as_doc, "issuer"),
         {:ok, authorize} <- required_safe_url(as_doc, "authorization_endpoint"),
         {:ok, token} <- required_safe_url(as_doc, "token_endpoint"),
         {:ok, registration} <- optional_safe_url(as_doc, "registration_endpoint") do
      {:ok,
       %{
         "issuer" => issuer,
         "authorization_endpoint" => authorize,
         "token_endpoint" => token,
         "registration_endpoint" => registration,
         "scopes_supported" => string_list(as_doc, "scopes_supported"),
         "code_challenge_methods_supported" =>
           optional_string_list(as_doc, "code_challenge_methods_supported"),
         "resource" => string_or_nil(pr_doc, "resource"),
         "authorization_servers" => string_list(pr_doc, "authorization_servers")
       }}
    end
  end

  defp required_string(doc, key) do
    case Map.get(doc, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_metadata_field, key}}
    end
  end

  # A required endpoint URL is server-controlled, so SafeUrl-validate it before
  # we accept (and later fetch/redirect to) it.
  defp required_safe_url(doc, key) do
    with {:ok, url} <- required_string(doc, key) do
      case SafeUrl.validate(url) do
        :ok -> {:ok, url}
        {:error, reason} -> {:error, {:unsafe_endpoint_url, key, reason}}
      end
    end
  end

  defp optional_safe_url(doc, key) do
    case Map.get(doc, key) do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      url when is_binary(url) ->
        case SafeUrl.validate(url) do
          :ok -> {:ok, url}
          {:error, reason} -> {:error, {:unsafe_endpoint_url, key, reason}}
        end

      _ ->
        {:error, {:invalid_metadata_field, key}}
    end
  end

  defp string_list(doc, key) do
    case Map.get(doc, key) do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  defp optional_string_list(doc, key) do
    case Map.get(doc, key) do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> nil
    end
  end

  defp string_or_nil(doc, key) do
    case Map.get(doc, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP + persistence
  # ---------------------------------------------------------------------------

  # SSRF-validate the URL, then GET + JSON-decode it. Every caller funnels its
  # server-controlled URL through here, so the SafeUrl gate is centralized.
  defp fetch_json(url) do
    with :ok <- safe(url),
         {:ok, %Req.Response{status: 200, body: body}} <- get(url),
         :ok <- within_size_limit(body),
         {:ok, doc} when is_map(doc) <- decode_body(body) do
      {:ok, doc}
    else
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:ok, _non_map} -> {:error, :unexpected_json_shape}
      {:error, _} = err -> err
      other -> {:error, {:fetch_failed, other}}
    end
  end

  defp within_size_limit(body) when is_binary(body) do
    if byte_size(body) <= @max_body_bytes, do: :ok, else: {:error, :response_too_large}
  end

  defp within_size_limit(_), do: :ok

  defp safe(url) do
    case SafeUrl.validate(url) do
      :ok -> :ok
      {:error, reason} -> {:error, {:unsafe_url, reason}}
    end
  end

  defp get(url) do
    Req.get(url,
      receive_timeout: @receive_timeout,
      decode_body: false,
      retry: false
    )
  rescue
    # Req can raise on transport-level failures; surface as a soft error so
    # discovery never crashes the caller.
    error -> {:error, {:request_raised, Exception.message(error)}}
  end

  defp decode_body(body) when is_binary(body), do: Jason.decode(body)
  defp decode_body(body) when is_map(body), do: {:ok, body}
  defp decode_body(_), do: {:error, :unexpected_body}

  # Build a well-known URL from the server/issuer base, dropping any trailing
  # slash so we never produce a double slash.
  defp join(base, path) do
    String.trim_trailing(base, "/") <> path
  end

  defp cache(server, metadata, actor) do
    case MCP.cache_server_oauth_metadata(server, %{oauth_metadata: metadata}, actor: actor) do
      {:ok, _updated} ->
        {:ok, metadata}

      {:error, reason} ->
        Logger.warning(
          "MCP OAuth discovery: failed to cache metadata for server #{server.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
