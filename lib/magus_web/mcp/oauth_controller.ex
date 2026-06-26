defmodule MagusWeb.MCP.OAuthController do
  @moduledoc """
  Browser-redirect OAuth 2.1 entrypoint for connecting Magus (an MCP *client*) to
  a remote MCP server on behalf of the logged-in user.

  Flow (mirrors the integrations `MagusWeb.OAuthController`, but per-MCP-server):

    1. The SPA settings page links the browser to `start/2`, which actor-scopes
       the server, builds the authorize URL via `Magus.MCP.Auth.Flow`, and
       redirects the browser to the provider's consent screen.
    2. The provider redirects back to `callback/2` with `code` + `state` (or an
       `error`). `callback/2` verifies the `state` (HMAC + single-use PKCE
       verifier), asserts the cross-bindings, exchanges the code for tokens, and
       persists them on the per-user `Magus.MCP.ServerCredential`.

  ## Redirect-target + query-param contract (READ BY THE SPA — Task 6)

  The MCP settings UI is SPA-only, served under `/next`. Every branch performs an
  INTERNAL redirect to `/next/settings/mcp-servers` with exactly one query param.
  Phoenix flash does not reach the client-rendered SPA, so the query param — not
  the flash — is the contract:

    * `?mcp_oauth=connected`          — success: tokens stored, status :connected.
    * `?mcp_oauth_error=<code>`       — failure, where `<code>` is one of the FIXED
      safe set (no secret ever leaks): `client_id_required | discovery_failed |
      not_oauth | invalid_state | denied | exchange_failed | server_unavailable`.

  ## Security

    * `start/2` and `callback/2` actor-scope every server load to the session user
      (a user may only connect a server they can read). A not-found and a
      forbidden server produce the SAME redirect — no enumeration.
    * `callback/2` verifies the `state` signature/freshness AND asserts the
      session user == state user AND the path server_id == state server_id before
      doing anything. Any mismatch stores NOTHING.
    * No token / refresh_token / code / verifier is ever placed in a redirect,
      query param, flash, or log line. Only the fixed non-secret error codes.
    * Every branch ends in a redirect; the `Flow` calls return tagged tuples (they
      never raise into the controller), so there is no 500 path.
  """

  use MagusWeb, :controller

  require Logger

  alias Magus.MCP
  alias Magus.MCP.Auth.Flow
  alias Magus.MCP.Auth.State

  # SPA-only MCP settings page (served under /next). Internal redirect target.
  @settings_path "/next/settings/mcp-servers"

  # The fixed, non-secret set of error codes the SPA may receive. Anything else
  # would risk leaking provider/secret detail, so the controller only ever emits
  # one of these.
  @error_codes ~w(client_id_required discovery_failed not_oauth invalid_state denied exchange_failed server_unavailable)

  @doc """
  GET /oauth/mcp/:server_id/start

  Starts the OAuth flow: actor-scopes the server to the session user, builds the
  authorize URL, and redirects the browser to the provider. On any failure,
  redirects back to the SPA settings page with a non-secret `mcp_oauth_error`.
  """
  def start(conn, %{"server_id" => server_id}) do
    user = conn.assigns.current_user

    with {:ok, server} <- load_server(server_id, user),
         :ok <- ensure_oauth(server) do
      callback_uri = url(conn, ~p"/oauth/mcp/#{server_id}/callback")

      case Flow.authorize_url(server, user, callback_uri) do
        {:ok, authorize_url} ->
          redirect(conn, external: authorize_url)

        {:error, :client_id_required} ->
          redirect_to_settings(conn, mcp_oauth_error: "client_id_required")

        {:error, reason} ->
          Logger.warning(
            "MCP OAuth start failed for server #{server_id}: #{inspect(sanitize(reason))}"
          )

          redirect_to_settings(conn, mcp_oauth_error: "discovery_failed")
      end
    else
      {:error, :not_oauth} ->
        redirect_to_settings(conn, mcp_oauth_error: "not_oauth")

      {:error, :server_unavailable} ->
        redirect_to_settings(conn, mcp_oauth_error: "server_unavailable")
    end
  end

  @doc """
  GET /oauth/mcp/:server_id/callback

  Two clauses, matched in order:

    * provider-error (`?error=...`): the provider denied/failed (e.g.
      `access_denied`). Redirects with `mcp_oauth_error=denied`; does NOT touch
      the credential. Must match BEFORE the success clause.
    * success (`?code=...&state=...`): verifies the `state`, asserts the
      cross-bindings, exchanges the code, and persists the tokens.
  """
  def callback(conn, %{"server_id" => server_id, "error" => error}) do
    Logger.warning(
      "MCP OAuth callback provider error for server #{server_id}: #{safe_error(error)}"
    )

    redirect_to_settings(conn, mcp_oauth_error: "denied")
  end

  # Success clause: verifies the `state` (HMAC + single-use PKCE verifier),
  # asserts the cross-bindings (session user == state user, path server_id ==
  # state server_id), exchanges the `code` for tokens, and persists them (status →
  # :connected). Stores NOTHING on any verification or exchange failure.
  def callback(conn, %{"server_id" => server_id, "code" => code, "state" => state}) do
    user = conn.assigns.current_user

    with {:ok, claims} <- verify_state(state),
         :ok <- assert_bindings(user, server_id, claims),
         {:ok, server} <- load_server(server_id, user),
         callback_uri = url(conn, ~p"/oauth/mcp/#{server_id}/callback"),
         {:ok, tokens} <- exchange(server, user, code, claims.verifier, callback_uri),
         {:ok, _credential} <- persist_tokens(server_id, tokens, user) do
      redirect_to_settings(conn, mcp_oauth: "connected")
    else
      {:error, :invalid_state} ->
        redirect_to_settings(conn, mcp_oauth_error: "invalid_state")

      {:error, :server_unavailable} ->
        redirect_to_settings(conn, mcp_oauth_error: "server_unavailable")

      {:error, :exchange_failed} ->
        redirect_to_settings(conn, mcp_oauth_error: "exchange_failed")
    end
  end

  # --- internals -------------------------------------------------------------

  # Actor-scoped load. A not-found server and a forbidden server both collapse to
  # the SAME {:error, :server_unavailable} — no enumeration of others' servers.
  defp load_server(server_id, user) do
    case MCP.get_server(server_id, actor: user) do
      {:ok, %MCP.Server{} = server} -> {:ok, server}
      _ -> {:error, :server_unavailable}
    end
  end

  defp ensure_oauth(%MCP.Server{auth_type: :oauth}), do: :ok
  defp ensure_oauth(%MCP.Server{}), do: {:error, :not_oauth}

  # Collapse every State.verify/1 failure (:invalid_state | :expired |
  # :no_verifier) to a single non-secret :invalid_state — the SPA does not need
  # to distinguish them and a finer code could aid probing.
  defp verify_state(state) do
    case State.verify(state) do
      {:ok, claims} -> {:ok, claims}
      {:error, _reason} -> {:error, :invalid_state}
    end
  end

  # Cross-binding assertions: the callback must run under the SAME session user
  # the state was issued for, against the SAME server in the path. Prevents a
  # callback being replayed under a different session/server. Compared as strings
  # since the path/claims carry string ids and user.id is a UUID struct/binary.
  defp assert_bindings(user, server_id, %{user_id: state_user_id, server_id: state_server_id}) do
    if to_string(user.id) == to_string(state_user_id) and
         to_string(server_id) == to_string(state_server_id) do
      :ok
    else
      {:error, :invalid_state}
    end
  end

  defp exchange(server, user, code, verifier, callback_uri) do
    case Flow.exchange_code(server, user, code, verifier, callback_uri) do
      {:ok, tokens} ->
        {:ok, tokens}

      {:error, reason} ->
        Logger.warning("MCP OAuth code exchange failed: #{inspect(sanitize(reason))}")
        {:error, :exchange_failed}
    end
  end

  # Persist the access/refresh tokens (string keys — the convention the executor
  # and the rest of the credential code use) + expiry. Status → :connected.
  #
  # `oauth_client` is DELIBERATELY OMITTED: `store_oauth_tokens` lists it in
  # `upsert_fields`, but AshPostgres only writes upsert fields that are actually
  # changing in the changeset (it filters upsert_fields to changing attributes —
  # see ash_postgres data_layer `upsert_set/4`). Since we don't set `oauth_client`
  # here, it is excluded from the ON CONFLICT SET clause and the previously
  # persisted client (written by Flow.authorize_url) is preserved — the
  # executor's refresh needs that client_id.
  #
  # Normalizes ANY persist failure (Ash.Error.Invalid / .Forbidden from a DB,
  # policy, or Vault-encryption error) to the non-secret `{:error,
  # :exchange_failed}` — mirroring how `exchange/5` normalizes its errors — so the
  # callback `with/else` stays exhaustive and every branch ends in a redirect,
  # never a raw 500. A finer code would risk leaking persistence detail.
  defp persist_tokens(server_id, tokens, user) do
    case MCP.store_oauth_tokens(
           %{
             mcp_server_id: server_id,
             oauth_tokens: %{
               "access_token" => tokens.access_token,
               "refresh_token" => tokens.refresh_token
             },
             oauth_expires_at: tokens.expires_at
           },
           actor: user
         ) do
      {:ok, credential} ->
        {:ok, credential}

      {:error, reason} ->
        Logger.warning("MCP OAuth token persist failed: #{inspect(sanitize(reason))}")
        {:error, :exchange_failed}
    end
  end

  # Centralized contract helper: every redirect goes to the SPA settings page with
  # exactly one query param. Guards that the value is one of the fixed safe codes
  # (or the success marker) so a secret can never slip into the URL.
  defp redirect_to_settings(conn, mcp_oauth: "connected") do
    redirect(conn, to: "#{@settings_path}?#{URI.encode_query(%{"mcp_oauth" => "connected"})}")
  end

  defp redirect_to_settings(conn, mcp_oauth_error: code) when code in @error_codes do
    redirect(conn, to: "#{@settings_path}?#{URI.encode_query(%{"mcp_oauth_error" => code})}")
  end

  # Only echo a provider `error` value if it is a short, known-safe token; never
  # log arbitrary provider-supplied content verbatim beyond a bounded slice.
  defp safe_error(error) when is_binary(error), do: String.slice(error, 0, 64)
  defp safe_error(_error), do: "unknown"

  # Reduce any error term to a non-secret summary for logging (tokens/secrets can
  # never appear in a log line).
  defp sanitize({tag, _detail}) when is_atom(tag), do: tag
  defp sanitize(reason) when is_atom(reason), do: reason
  defp sanitize(_reason), do: :oauth_request_failed
end
