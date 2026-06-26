defmodule Magus.MCP.ExecutorOAuthTest do
  @moduledoc """
  Drives the OAuth execution path of `Magus.MCP.Executor`: Bearer-header
  injection from stored tokens, near-expiry preflight refresh, and the
  refresh-and-retry on a 401/-32001 from the dial.

  Two Bypass instances:

    * an MCP server (Streamable HTTP) that injects the request `Authorization`
      header into an Agent so a test can assert which Bearer was sent, and can
      be told to reply 401/-32001 for a "stale" token then succeed for the
      refreshed one, and
    * the OAuth authorization server (`/token` + discovery) that `Flow.refresh`
      hits.

  No live network, real oidcc, real DB + `ClientManager`. The acting user owns
  the per-user `ServerCredential`, so refresh/store/status all run actor-scoped.
  """
  use Magus.ResourceCase, async: false

  alias Magus.MCP
  alias Magus.MCP.Executor

  @moduletag :mcp_integration

  setup do
    user = generate(user())
    %{user: user}
  end

  defp context(user), do: %{user: user, conversation_id: nil, user_id: user.id}

  # ---------------------------------------------------------------------------
  # MCP server Bypass: a Streamable-HTTP mock that records the Bearer it saw and
  # can be flipped to reply 401 until a "fresh" token arrives.
  # ---------------------------------------------------------------------------

  @session_id "mock-session-id"

  # `state` (an Agent pid) carries:
  #   bearers:     list of Authorization headers seen on tools/call (newest first)
  #   reject_until: a token string; while the call's Bearer == "Bearer <stale>"
  #                 the server replies -32001 unauthorized. When nil, every
  #                 authenticated call succeeds.
  defp start_mcp_server(opts \\ []) do
    reject_stale = Keyword.get(opts, :reject_stale, nil)

    {:ok, state} =
      start_supervised(
        Supervisor.child_spec(
          {Agent, fn -> %{bearers: [], reject_stale: reject_stale} end},
          id: {:mcp_state, System.unique_integer([:positive])}
        )
      )

    bypass = Bypass.open()

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      bearer = conn |> Plug.Conn.get_req_header("authorization") |> List.first()
      respond(conn, request, bearer, state)
    end)

    Bypass.stub(bypass, "DELETE", "/mcp", fn conn -> Plug.Conn.resp(conn, 200, "") end)

    %{bypass: bypass, state: state}
  end

  defp respond(conn, %{"method" => "initialize", "id" => id}, _bearer, _state) do
    conn
    |> Plug.Conn.put_resp_header("mcp-session-id", @session_id)
    |> json(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => "2025-06-18",
        "serverInfo" => %{"name" => "mock", "version" => "1.0.0"},
        "capabilities" => %{"tools" => %{}}
      }
    })
  end

  defp respond(conn, %{"method" => "tools/list", "id" => id}, _bearer, _state) do
    json(conn, %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"tools" => [%{"name" => "echo", "inputSchema" => %{}}]}
    })
  end

  defp respond(conn, %{"method" => "tools/call", "id" => id}, bearer, state) do
    Agent.update(state, fn s -> %{s | bearers: [bearer | s.bearers]} end)
    reject_stale = Agent.get(state, & &1.reject_stale)

    if is_binary(reject_stale) and bearer == "Bearer " <> reject_stale do
      # JSON-RPC unauthorized: classify/1 maps -32001 to :needs_auth.
      json(conn, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => -32_001, "message" => "unauthorized"}
      })
    else
      json(conn, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "result" => %{"content" => [%{"type" => "text", "text" => "ok"}], "isError" => false}
      })
    end
  end

  defp respond(conn, _notification, _bearer, _state) do
    Plug.Conn.resp(conn, 202, "")
  end

  defp json(conn, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(payload))
  end

  # ---------------------------------------------------------------------------
  # OAuth AS Bypass: /token + discovery. Counts /token hits so a test can assert
  # refresh was (not) attempted.
  # ---------------------------------------------------------------------------

  defp start_as_server do
    bypass = Bypass.open()
    base = "http://127.0.0.1:#{bypass.port}"

    {:ok, counter} =
      start_supervised(
        Supervisor.child_spec({Agent, fn -> 0 end},
          id: {:token_counter, System.unique_integer([:positive])}
        )
      )

    %{bypass: bypass, base: base, counter: counter}
  end

  # `/token` returns the given JSON body at `status`, incrementing the hit counter.
  defp stub_token(as, status, body) do
    Bypass.stub(as.bypass, "POST", "/token", fn conn ->
      Agent.update(as.counter, &(&1 + 1))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)
  end

  # The metadata we cache on the server so `Flow.refresh` resolves the token
  # endpoint without a discovery round-trip (mirrors the flow_test approach).
  defp oauth_metadata(as) do
    %{
      "issuer" => as.base,
      "authorization_endpoint" => "#{as.base}/authorize",
      "token_endpoint" => "#{as.base}/token",
      "registration_endpoint" => nil,
      "scopes_supported" => ["mcp"],
      "code_challenge_methods_supported" => ["S256"],
      "resource" => as.base,
      "authorization_servers" => [as.base]
    }
  end

  # ---------------------------------------------------------------------------
  # Server + credential setup
  # ---------------------------------------------------------------------------

  # Build an :oauth server pointed at the MCP Bypass, with the AS's metadata
  # cached on it. Returns the reloaded server (carrying oauth_metadata).
  defp oauth_server(user, mcp, as) do
    {:ok, server} =
      MCP.create_server(
        %{
          name: "OAuthSvc",
          handle: "oauthsvc#{System.unique_integer([:positive])}",
          url: "http://127.0.0.1:#{mcp.bypass.port}",
          mcp_path: "/mcp",
          auth_type: :oauth
        },
        actor: user
      )

    {:ok, server} =
      MCP.cache_server_oauth_metadata(server, %{oauth_metadata: oauth_metadata(as)}, actor: user)

    server
  end

  defp seed_tokens(user, server, attrs) do
    {:ok, credential} =
      MCP.store_oauth_tokens(
        Map.merge(
          %{
            mcp_server_id: server.id,
            oauth_client: %{"client_id" => "dcr-client-id"}
          },
          attrs
        ),
        actor: user
      )

    credential
  end

  defp reload_credential(user, server) do
    {:ok, credential} = MCP.get_credential_for_server(server.id, actor: user)
    credential
  end

  # The very first dial to a freshly-opened Bypass can exceed the tight test
  # `init_timeout_ms`; prime the connection pool so the assertions see the warm
  # client behavior (clients are reused).
  defp warm_up(server, attempts \\ 3) do
    case MCP.ClientManager.with_client(server, %{}, fn client ->
           MCP.Client.list_tools(client)
         end) do
      {:ok, _} -> :ok
      _ when attempts > 1 -> warm_up(server, attempts - 1)
      _ -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # happy path
  # ---------------------------------------------------------------------------

  test "valid non-expiring token: call succeeds with the stored Bearer, no refresh", %{
    user: user
  } do
    mcp = start_mcp_server()
    as = start_as_server()
    server = oauth_server(user, mcp, as)
    warm_up(server)

    seed_tokens(user, server, %{
      oauth_tokens: %{"access_token" => "valid-access", "refresh_token" => "r"},
      oauth_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    })

    assert {:ok, result} = Executor.call(server, "echo", %{"text" => "hi"}, context(user))
    refute Map.has_key?(result, :error)
    assert %{"content" => [%{"type" => "text", "text" => "ok"}]} = result

    # The stored token was sent, and /token was NOT hit.
    assert "Bearer valid-access" in Agent.get(mcp.state, & &1.bearers)
    assert Agent.get(as.counter, & &1) == 0
  end

  # ---------------------------------------------------------------------------
  # near-expiry preflight refresh
  # ---------------------------------------------------------------------------

  test "near-expiry token: preflight refresh re-stores tokens and calls with the new Bearer", %{
    user: user
  } do
    mcp = start_mcp_server()
    as = start_as_server()
    server = oauth_server(user, mcp, as)
    warm_up(server)

    # AS rotates the refresh token on refresh.
    stub_token(as, 200, %{
      "access_token" => "fresh-access",
      "refresh_token" => "rotated-refresh",
      "token_type" => "Bearer",
      "expires_in" => 3600
    })

    seed_tokens(user, server, %{
      oauth_tokens: %{"access_token" => "about-to-expire", "refresh_token" => "old-refresh"},
      # within the 60s skew window -> preflight refresh fires
      oauth_expires_at: DateTime.add(DateTime.utc_now(), 30, :second)
    })

    assert {:ok, result} = Executor.call(server, "echo", %{}, context(user))
    refute Map.has_key?(result, :error)

    # Refresh happened exactly once, and the call used the fresh Bearer.
    assert Agent.get(as.counter, & &1) == 1
    assert "Bearer fresh-access" in Agent.get(mcp.state, & &1.bearers)
    refute "Bearer about-to-expire" in Agent.get(mcp.state, & &1.bearers)

    # New tokens + rotation persisted.
    cred = reload_credential(user, server)
    assert cred.oauth_tokens["access_token"] == "fresh-access"
    assert cred.oauth_tokens["refresh_token"] == "rotated-refresh"
  end

  # ---------------------------------------------------------------------------
  # 401 refresh-and-retry
  # ---------------------------------------------------------------------------

  test "401 on the first dial: refresh then re-dial succeeds; new token stored", %{user: user} do
    # The server rejects the stale token with -32001; the refreshed token works.
    mcp = start_mcp_server(reject_stale: "stale-access")
    as = start_as_server()
    server = oauth_server(user, mcp, as)
    warm_up(server)

    stub_token(as, 200, %{
      "access_token" => "retry-access",
      "refresh_token" => "retry-refresh",
      "token_type" => "Bearer",
      "expires_in" => 3600
    })

    # Not near expiry: preflight is skipped, so the stale token is sent and 401s.
    seed_tokens(user, server, %{
      oauth_tokens: %{"access_token" => "stale-access", "refresh_token" => "old-refresh"},
      oauth_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    })

    assert {:ok, result} = Executor.call(server, "echo", %{}, context(user))
    refute Map.has_key?(result, :error)

    # Exactly one refresh, and both the stale (first dial) and retry Bearers seen.
    assert Agent.get(as.counter, & &1) == 1
    bearers = Agent.get(mcp.state, & &1.bearers)
    assert "Bearer stale-access" in bearers
    assert "Bearer retry-access" in bearers

    cred = reload_credential(user, server)
    assert cred.oauth_tokens["access_token"] == "retry-access"
  end

  # ---------------------------------------------------------------------------
  # refresh invalid_grant
  # ---------------------------------------------------------------------------

  test "preflight refresh invalid_grant: soft needs-auth error + status :needs_auth", %{
    user: user
  } do
    mcp = start_mcp_server()
    as = start_as_server()
    server = oauth_server(user, mcp, as)
    warm_up(server)

    stub_token(as, 400, %{"error" => "invalid_grant"})

    seed_tokens(user, server, %{
      oauth_tokens: %{"access_token" => "x", "refresh_token" => "revoked"},
      # near expiry -> preflight refresh -> invalid_grant
      oauth_expires_at: DateTime.add(DateTime.utc_now(), 10, :second)
    })

    assert {:ok, %{error: msg}} = Executor.call(server, "echo", %{}, context(user))
    assert is_binary(msg)
    assert msg =~ "auth" or msg =~ "connect"

    # No dial happened (preflight failed) and the credential is marked needs_auth.
    assert Agent.get(mcp.state, & &1.bearers) == []
    assert reload_credential(user, server).status == :needs_auth
  end

  test "401 then refresh invalid_grant: soft needs-auth error + status :needs_auth", %{
    user: user
  } do
    mcp = start_mcp_server(reject_stale: "stale-access")
    as = start_as_server()
    server = oauth_server(user, mcp, as)
    warm_up(server)

    stub_token(as, 400, %{"error" => "invalid_grant"})

    seed_tokens(user, server, %{
      oauth_tokens: %{"access_token" => "stale-access", "refresh_token" => "revoked"},
      oauth_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    })

    assert {:ok, %{error: msg}} = Executor.call(server, "echo", %{}, context(user))
    assert is_binary(msg)
    assert reload_credential(user, server).status == :needs_auth
  end

  # ---------------------------------------------------------------------------
  # no tokens
  # ---------------------------------------------------------------------------

  test "oauth server with a credential row but no tokens: :needs_auth soft error, no dial", %{
    user: user
  } do
    mcp = start_mcp_server()
    as = start_as_server()
    server = oauth_server(user, mcp, as)
    warm_up(server)

    # A credential row exists (client persisted) but no oauth_tokens yet.
    {:ok, _} =
      MCP.store_oauth_client(
        %{mcp_server_id: server.id, oauth_client: %{"client_id" => "c"}},
        actor: user
      )

    assert {:ok, %{error: msg}} = Executor.call(server, "echo", %{}, context(user))
    assert is_binary(msg)
    assert msg =~ "auth" or msg =~ "connect"
    assert Agent.get(mcp.state, & &1.bearers) == []
    # No refresh attempted with no tokens.
    assert Agent.get(as.counter, & &1) == 0
  end

  test "oauth server with NO credential row at all: :needs_auth soft error", %{user: user} do
    mcp = start_mcp_server()
    as = start_as_server()
    server = oauth_server(user, mcp, as)
    warm_up(server)

    assert {:ok, %{error: msg}} = Executor.call(server, "echo", %{}, context(user))
    assert is_binary(msg)
    assert msg =~ "auth" or msg =~ "connect"
  end
end
