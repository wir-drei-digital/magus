defmodule Magus.MCP.Executor do
  @moduledoc """
  Single execution funnel for one MCP tool call. Resolves the acting user's
  per-user credential, dials the server via `Magus.MCP.ClientManager`, and
  normalizes EVERY outcome (success, auth failure, dead client, timeout,
  method-not-found, unexpected exception) to an LLM-actionable `{:ok, map}`.

  The runner dispatches this result directly and has no error handling for MCP,
  so `call/4` MUST ALWAYS return `{:ok, map}`:

    * Success: `{:ok, payload_map}` (the normalized tool result).
    * Soft error: `{:ok, %{error: binary}}` (an actionable message the LLM can
      act on, e.g. "ask the user to connect it in settings").

  It never raises and never returns `{:error, _}` to the caller.

  Auth: `:none` and `:static_header` resolve a fixed header map up front and
  dial once. `:oauth` builds a `Bearer` from the acting user's stored tokens,
  preflight-refreshes when the access token is near expiry, and — if the dial
  still comes back unauthorized (401 / -32001) — refreshes once and retries with
  a fresh short-lived client. A pre-dial auth failure (no tokens, or a preflight
  refresh that is `invalid_grant`) is a `:needs_auth` soft error with NO retry;
  only a dial that returned `:needs_auth` after a Bearer was successfully built
  triggers the single refresh-and-retry. SSRF re-validation at dial time lives
  inside `ClientManager` (and inside `Auth.Flow` for the token endpoint) and is
  relied upon here, not duplicated.

  Tokens (access / refresh) NEVER appear in any log, error term, or exception
  message.
  """

  require Logger

  alias Magus.Accounts.User
  alias Magus.MCP
  alias Magus.MCP.{Client, ClientManager, Server, ServerCredential}
  alias Magus.MCP.Auth.Flow

  # Refresh the access token when it expires within this skew window, so a token
  # that is technically still valid at resolve time does not expire mid-flight.
  @expiry_skew_seconds 60

  # The runner does not bound the call, so we enforce a finite ceiling here.
  # `Client.call_tool/3` has no timeout option, so the call runs inside a Task
  # that we yield on for at most this long; a timeout becomes a soft error.
  @call_timeout_ms 30_000

  @spec call(Server.t(), String.t(), map(), map()) :: {:ok, map()}
  def call(%Server{enabled?: false} = server, _remote_name, _args, _context) do
    {:ok, soft_error("MCP server #{server.handle} is disabled. Ask the user to enable it.")}
  end

  def call(%Server{} = server, remote_name, args, context) do
    acting_user = context[:user]

    with {:ok, payload} <- run(server, acting_user, remote_name, args) do
      {:ok, ensure_map(payload)}
    else
      {:error, :needs_auth} ->
        {:ok,
         soft_error(
           "MCP server #{server.handle} needs authorization. Ask the user to connect it in settings."
         )}

      {:error, :no_credential} ->
        {:ok,
         soft_error(
           "No credential for MCP server #{server.handle}. Ask the user to configure it in settings."
         )}

      {:error, :method_not_found} ->
        # The cached tool list is stale: this tool no longer exists remotely.
        # The async cache refresh is deferred (Phase 2), so just steer the LLM
        # back to discovery.
        {:ok,
         soft_error(
           "Tool '#{remote_name}' is no longer available on #{server.handle}. Call tool_search to find current tools."
         )}

      {:error, :timeout} ->
        Logger.warning("MCP call timed out (#{server.handle}/#{remote_name})")
        {:ok, soft_error("MCP server #{server.handle} timed out. Try again later.")}

      {:error, reason} ->
        Logger.warning("MCP call failed (#{server.handle}/#{remote_name}): #{inspect(reason)}")

        {:ok, soft_error("MCP server #{server.handle} is unavailable. Try again later.")}
    end
  rescue
    e ->
      Logger.error(
        "MCP executor crashed (#{server.handle}/#{remote_name}): #{Exception.message(e)}"
      )

      {:ok, soft_error("MCP server #{server.handle} errored.")}
  catch
    kind, reason ->
      Logger.error(
        "MCP executor caught #{kind} (#{server.handle}/#{remote_name}): #{inspect(reason)}"
      )

      {:ok, soft_error("MCP server #{server.handle} errored.")}
  end

  # --- dispatch by auth type -------------------------------------------------

  # `:oauth` is handled by a dedicated path that holds the credential + user +
  # server in scope, so the 401 refresh-and-retry can reuse them WITHOUT
  # conflating its dial-time `:needs_auth` with the pre-dial `:needs_auth` that
  # `resolve_oauth_headers/2` returns (no tokens / preflight invalid_grant).
  # Static / none resolve a fixed header map and dial exactly once.
  defp run(%Server{auth_type: :oauth} = server, user, remote_name, args),
    do: oauth_call(server, user, remote_name, args)

  defp run(server, user, remote_name, args) do
    with {:ok, headers} <- resolve_headers(server, user) do
      dial_and_call(server, headers, remote_name, args)
    end
  end

  # --- oauth: preflight refresh + dial + single 401 refresh-retry -------------

  # Match SPECIFICALLY on a loaded %User{} (like static_header): an
  # %Ash.NotLoaded{} / nil actor falls through to {:error, :no_credential}.
  defp oauth_call(%Server{} = server, %User{} = user, remote_name, args) do
    # PRE-DIAL: resolve the Bearer (loading + preflight-refreshing the
    # credential). A failure here is terminal — NO retry.
    with {:ok, headers, credential} <- resolve_oauth_headers(server, user) do
      # DIAL: a 401 / -32001 here (after a Bearer WAS built) is the ONLY thing
      # that triggers the single refresh-and-retry.
      case dial_and_call(server, headers, remote_name, args) do
        {:error, :needs_auth} ->
          oauth_refresh_and_retry(server, user, credential, remote_name, args)

        other ->
          other
      end
    end
  end

  defp oauth_call(_server, _user, _remote_name, _args), do: {:error, :no_credential}

  # Load the acting user's credential and build the Bearer header, preflight-
  # refreshing when the token is near expiry. Returns the credential alongside
  # the headers so the 401-retry can reuse it without re-reading.
  defp resolve_oauth_headers(server, user) do
    case MCP.get_credential_for_server(server.id, actor: user) do
      {:ok, %ServerCredential{oauth_tokens: tokens} = credential}
      when is_map(tokens) and map_size(tokens) > 0 ->
        preflight(server, user, credential)

      # No row, or a row with no usable tokens yet: the user must connect first.
      {:ok, _} ->
        {:error, :needs_auth}

      {:error, _} ->
        {:error, :needs_auth}
    end
  end

  # If the access token is non-nil and within the skew window, refresh BEFORE
  # dialing so we never send a token that expires mid-flight. A nil expiry skips
  # preflight (we rely on the 401-retry instead).
  defp preflight(server, user, %ServerCredential{oauth_expires_at: expires_at} = credential) do
    if near_expiry?(expires_at) do
      case Flow.refresh(server, credential) do
        {:ok, new_tokens} ->
          credential = store_refreshed!(credential, user, new_tokens)
          with_bearer(new_tokens.access_token, credential)

        {:error, :invalid_grant} ->
          mark_needs_auth(credential, user)
          {:error, :needs_auth}

        # Transient refresh failure: surface needs_auth (soft) rather than crash;
        # the user can retry/reconnect. The reason is not token-bearing, but we
        # do not log it here to keep the no-token-leak guarantee airtight.
        {:error, _other} ->
          {:error, :needs_auth}
      end
    else
      with_bearer(access_token(credential), credential)
    end
  end

  # Single refresh-and-retry after a 401 from the dial. Refresh once, re-store,
  # rebuild the Bearer, and dial again with a fresh short-lived client. If the
  # refresh fails OR the retry still 401s, mark the credential needs_auth.
  defp oauth_refresh_and_retry(server, user, credential, remote_name, args) do
    case Flow.refresh(server, credential) do
      {:ok, new_tokens} ->
        store_refreshed!(credential, user, new_tokens)
        retry_dial(server, user, credential, new_tokens.access_token, remote_name, args)

      {:error, _reason} ->
        mark_needs_auth(credential, user)
        {:error, :needs_auth}
    end
  end

  # The single retry dial. A success (or any non-auth error) passes straight
  # through; only a STILL-unauthorized result — or a missing access token —
  # marks the credential needs_auth. There is no further retry.
  defp retry_dial(server, user, credential, access_token, remote_name, args) do
    with {:ok, headers} <- bearer(access_token),
         result <- dial_and_call(server, headers, remote_name, args) do
      case result do
        {:error, :needs_auth} ->
          mark_needs_auth(credential, user)
          {:error, :needs_auth}

        other ->
          other
      end
    else
      {:error, :needs_auth} ->
        mark_needs_auth(credential, user)
        {:error, :needs_auth}
    end
  end

  # --- oauth token helpers ----------------------------------------------------

  defp near_expiry?(%DateTime{} = expires_at) do
    DateTime.compare(expires_at, DateTime.add(DateTime.utc_now(), @expiry_skew_seconds, :second)) !=
      :gt
  end

  defp near_expiry?(_expires_at), do: false

  defp access_token(%ServerCredential{oauth_tokens: tokens}) when is_map(tokens),
    do: tokens["access_token"]

  defp access_token(_credential), do: nil

  # Build the {:ok, headers, credential} tuple `resolve_oauth_headers/2` returns,
  # short-circuiting to needs_auth when there is no usable access token.
  defp with_bearer(token, credential) do
    case bearer(token) do
      {:ok, headers} -> {:ok, headers, credential}
      {:error, :needs_auth} = err -> err
    end
  end

  defp bearer(token) when is_binary(token) and token != "",
    do: {:ok, %{"Authorization" => "Bearer " <> token}}

  # A missing/blank access_token cannot build a Bearer; treat as needs_auth.
  defp bearer(_token), do: {:error, :needs_auth}

  defp store_refreshed!(credential, user, new_tokens) do
    # Re-store the rotated tokens (string-keyed shape, matching the Task 4
    # controller's `persist_tokens`) actor-scoped as the owning user. A persist
    # failure must not crash; return the in-memory credential so the dial still
    # uses the fresh token (the outer wrapper guarantees a soft error regardless).
    params = %{
      oauth_tokens: %{
        "access_token" => new_tokens.access_token,
        "refresh_token" => new_tokens.refresh_token
      },
      oauth_expires_at: new_tokens.expires_at
    }

    case MCP.refresh_oauth_tokens(credential, params, actor: user) do
      {:ok, updated} -> updated
      {:error, _reason} -> credential
    end
  end

  # Mark the credential needs-auth so the SPA prompts a reconnect. A persist
  # failure here is non-fatal: the caller already returns the soft needs_auth.
  defp mark_needs_auth(credential, user) do
    case MCP.set_credential_status(credential, %{status: :needs_auth}, actor: user) do
      {:ok, _} -> :ok
      {:error, _reason} -> :ok
    end
  end

  # --- static / none credential resolution -----------------------------------

  defp resolve_headers(%Server{auth_type: :none}, _user), do: {:ok, %{}}

  # Match SPECIFICALLY on a loaded %User{}. A wildcard `%_{}` would also match
  # an `%Ash.NotLoaded{}` and hand a bogus actor to Ash. A NotLoaded / non-User /
  # nil user falls through to the `{:error, :no_credential}` clause below.
  defp resolve_headers(%Server{auth_type: :static_header} = server, %User{} = user) do
    case MCP.get_credential_for_server(server.id, actor: user) do
      {:ok, %{static_headers: headers}} when is_map(headers) and map_size(headers) > 0 ->
        {:ok, headers}

      # Credential row exists but has no usable headers, or there is no row
      # (get?: true returns {:ok, nil} when the user has no credential).
      {:ok, _} ->
        {:error, :no_credential}

      {:error, _} ->
        {:error, :no_credential}
    end
  end

  # Acting user is required to read a per-user credential; without one (or an
  # unknown auth type) there is nothing we can safely dial with.
  defp resolve_headers(_server, _user), do: {:error, :no_credential}

  # --- dial + call -----------------------------------------------------------

  defp dial_and_call(server, headers, remote_name, args) do
    ClientManager.with_client(server, headers, fn client ->
      bounded_call(client, remote_name, args)
    end)
  end

  # `Client.call_tool/3` is synchronous with no timeout, so run it in a Task and
  # yield for at most @call_timeout_ms. A timeout is a soft error; we shut the
  # Task down so it cannot leak.
  defp bounded_call(client, remote_name, args) do
    # `async_nolink` (not `async`) is deliberate: the spawned task is NOT linked
    # to this process, so an abnormal exit inside `Client.call_tool` (e.g. a
    # `GenServer.call` to a dead `restart: :transient` anubis client that
    # returns a `:noproc` exit) surfaces to `Task.yield/2` as `{:exit, reason}`
    # instead of killing the caller via the link. That keeps the
    # `{:exit, reason}` branch reachable so every failure maps to a soft
    # `{:ok, %{error: ...}}`, preserving `call/4`'s always-`{:ok, map}` contract.
    # The unlinked task is owned by `Magus.MCP.TaskSupervisor`.
    task =
      Task.Supervisor.async_nolink(Magus.MCP.TaskSupervisor, fn ->
        Client.call_tool(client, remote_name, args)
      end)

    case Task.yield(task, @call_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, payload}} ->
        {:ok, payload}

      {:ok, {:error, reason}} ->
        {:error, classify(reason)}

      # Task.shutdown returns nil on timeout; the worker may also exit abnormally.
      nil ->
        {:error, :timeout}

      {:exit, reason} ->
        {:error, reason}
    end
  end

  # Map anubis/transport errors to the soft-error vocabulary above.
  #
  # Public with `@doc false` so the pure classification branches can be
  # unit-tested directly: reaching them through `call/4` would require the
  # mock to emit method-not-found / unauthorized JSON-RPC errors, which it
  # cannot. Not part of the supported API.
  @doc false
  def classify(reason) do
    cond do
      method_not_found?(reason) -> :method_not_found
      unauthorized?(reason) -> :needs_auth
      true -> reason
    end
  end

  # JSON-RPC method-not-found is -32601; tolerate atom- and string-keyed shapes
  # as well as the anubis error struct.
  defp method_not_found?(%{code: -32_601}), do: true
  defp method_not_found?(%{"code" => -32_601}), do: true
  defp method_not_found?(%{reason: :method_not_found}), do: true
  defp method_not_found?(_), do: false

  defp unauthorized?(%{code: code}) when code in [401, -32_001], do: true
  defp unauthorized?(%{"code" => code}) when code in [401, -32_001], do: true
  defp unauthorized?(_), do: false

  # --- helpers ---------------------------------------------------------------

  # The runner contract is {:ok, map}. Tool results are normally maps, but a
  # server could return a scalar/list; wrap those so callers always get a map.
  defp ensure_map(payload) when is_map(payload), do: payload
  defp ensure_map(payload), do: %{result: payload}

  defp soft_error(message), do: %{error: message}
end
