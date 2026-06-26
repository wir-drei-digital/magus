defmodule Magus.MCP.OAuthE2ETest do
  @moduledoc """
  Genuinely end-to-end OAuth 2.1 coverage for the MCP client — the cross-module
  chain that no single Task 1-6 unit/integration test exercises on its own, plus
  a consolidated security-properties suite asserted at the integration seams.

  ## Dual-Bypass harness

  Two independent Bypass servers stand in for the network (no live calls):

    * the **MCP server** (Streamable HTTP) — serves `tools/call` and records the
      inbound `Authorization` header so we can prove the executor sent the Bearer
      minted by the flow; it can be flipped to reply `-32001` (unauthorized) until
      a "fresh" token arrives. It ALSO serves the RFC 9728 protected-resource doc,
      pointing `authorization_servers` at the AS Bypass — so `start` discovers the
      AS for real, across Bypass instances.
    * the **OAuth authorization server (AS)** — serves RFC 8414 metadata,
      `/register` (DCR), and `/token` (code exchange + refresh).

  Everything else is real: the live HTTP controller (`start` + `callback`) under
  `MagusWeb.ConnCase` with a real logged-in session, real `Magus.MCP.Auth.{Flow,
  State,Discovery}`, real `Magus.Cache` (the server-side PKCE store), real
  `Magus.MCP.Executor` + `ClientManager`, and a real DB.

  ## What this file adds over the per-task tests

  The happy path drives the WHOLE chain through one running system:

      GET /start (302 → AS authorize, real issued `state` + cached verifier)
        → GET /callback?code&state (real State.verify consumes the cached
          verifier; Flow.exchange_code hits the AS /token; tokens persisted,
          status :connected)
        → Executor.call (loads the just-persisted credential, dials the MCP
          Bypass, which asserts it received `Authorization: Bearer <token>`).

  The `state` flows through the real `Magus.Cache` from `start` to `callback`
  (parsed back out of the `start` redirect's authorize URL), so the PKCE store is
  exercised end-to-end rather than stubbed.

  Refresh-on-401 and invalid_grant→`:needs_auth` are then asserted across the
  controller-persisted credential + the executor seam. The security describe
  block asserts SSRF, HMAC tamper, missing-verifier, cross-user state, and
  unauthorized-server rejection through the public `start`/`callback`/`Flow`
  entry points. Where a property is already covered verbatim by a prior task's
  test, the e2e version is justified only by the added cross-module coverage; see
  the module-level comments on each.
  """
  use MagusWeb.ConnCase, async: false

  import Magus.Generators

  alias Magus.MCP
  alias Magus.MCP.Auth.Flow
  alias Magus.MCP.Auth.State
  alias Magus.MCP.Executor

  @moduletag :mcp_integration

  @settings_path "/next/settings/mcp-servers"
  @session_id "mock-session-id"

  setup %{conn: conn} do
    user = generate(user())
    %{conn: log_in_user(conn, user), user: user}
  end

  # ConnCase has no session-login helper (it lives in LiveViewCase); establish the
  # session the same way the controller test does — a real AshAuthentication token
  # that the :browser pipeline reads into conn.assigns.current_user.
  defp log_in_user(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  defp context(user), do: %{user: user, conversation_id: nil, user_id: user.id}

  # ===========================================================================
  # MCP server Bypass (Streamable HTTP) — records the Bearer, serves discovery.
  # ===========================================================================

  # `state` (an Agent) carries:
  #   bearers:      Authorization headers seen on tools/call (newest first)
  #   reject_stale: while a call's Bearer == "Bearer <reject_stale>" the server
  #                 replies -32001; when nil, every authenticated call succeeds.
  #
  # The MCP Bypass also serves the RFC 9728 protected-resource doc advertising the
  # AS Bypass as the authorization server, so `start`'s discovery is real and
  # crosses Bypass instances.
  defp start_mcp_server(as_base, opts \\ []) do
    reject_stale = Keyword.get(opts, :reject_stale, nil)

    {:ok, state} =
      start_supervised(
        Supervisor.child_spec(
          {Agent, fn -> %{bearers: [], reject_stale: reject_stale} end},
          id: {:mcp_state, System.unique_integer([:positive])}
        )
      )

    bypass = Bypass.open()
    base = "http://127.0.0.1:#{bypass.port}"

    # RFC 9728 protected-resource metadata: names the AS Bypass as the AS.
    Bypass.stub(bypass, "GET", "/.well-known/oauth-protected-resource", fn conn ->
      json(conn, %{"resource" => base, "authorization_servers" => [as_base]})
    end)

    Bypass.stub(bypass, "POST", "/mcp", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      bearer = conn |> Plug.Conn.get_req_header("authorization") |> List.first()
      respond(conn, request, bearer, state)
    end)

    Bypass.stub(bypass, "DELETE", "/mcp", fn conn -> Plug.Conn.resp(conn, 200, "") end)

    %{bypass: bypass, base: base, state: state}
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

  defp respond(conn, _notification, _bearer, _state), do: Plug.Conn.resp(conn, 202, "")

  defp json(conn, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(payload))
  end

  # ===========================================================================
  # AS Bypass — RFC 8414 metadata + /register (DCR) + /token. Counts /token hits.
  # ===========================================================================

  defp start_as_server do
    bypass = Bypass.open()
    base = "http://127.0.0.1:#{bypass.port}"

    {:ok, token_counter} =
      start_supervised(
        Supervisor.child_spec({Agent, fn -> 0 end},
          id: {:token_counter, System.unique_integer([:positive])}
        )
      )

    %{bypass: bypass, base: base, token_counter: token_counter}
  end

  # Serve AS metadata at the AS base; by default advertise a /register endpoint.
  defp stub_as_metadata(as, overrides \\ %{}) do
    doc =
      Map.merge(
        %{
          "issuer" => as.base,
          "authorization_endpoint" => "#{as.base}/authorize",
          "token_endpoint" => "#{as.base}/token",
          "registration_endpoint" => "#{as.base}/register",
          "scopes_supported" => ["openid", "mcp"],
          "response_types_supported" => ["code"],
          "grant_types_supported" => ["authorization_code", "refresh_token"],
          "code_challenge_methods_supported" => ["S256"]
        },
        overrides
      )

    Bypass.stub(as.bypass, "GET", "/.well-known/oauth-authorization-server", fn conn ->
      json(conn, doc)
    end)

    as
  end

  defp stub_register(as, client_id \\ "dcr-client-id") do
    Bypass.stub(as.bypass, "POST", "/register", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(201, Jason.encode!(%{"client_id" => client_id}))
    end)

    as
  end

  # `/token` returns `body` at `status`, incrementing the hit counter.
  defp stub_token(as, status, body) do
    Bypass.stub(as.bypass, "POST", "/token", fn conn ->
      Agent.update(as.token_counter, &(&1 + 1))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)

    as
  end

  # ===========================================================================
  # Server + credential helpers
  # ===========================================================================

  defp oauth_server(actor, mcp, attrs \\ %{}) do
    {:ok, server} =
      MCP.create_server(
        Map.merge(
          %{
            name: "OAuthSvc",
            handle: "oauthsvc#{System.unique_integer([:positive])}",
            url: mcp.base,
            mcp_path: "/mcp",
            auth_type: :oauth
          },
          attrs
        ),
        actor: actor
      )

    server
  end

  # Cache the AS metadata on the server so the executor's refresh resolves the
  # token endpoint without a discovery round-trip (the executor leg does not run
  # discovery; mirrors executor_oauth_test). Returns the reloaded server.
  defp cache_metadata(server, mcp, as, actor) do
    {:ok, server} =
      MCP.cache_server_oauth_metadata(
        server,
        %{
          oauth_metadata: %{
            "issuer" => as.base,
            "authorization_endpoint" => "#{as.base}/authorize",
            "token_endpoint" => "#{as.base}/token",
            "registration_endpoint" => "#{as.base}/register",
            "scopes_supported" => ["mcp"],
            "code_challenge_methods_supported" => ["S256"],
            "resource" => mcp.base,
            "authorization_servers" => [as.base]
          }
        },
        actor: actor
      )

    server
  end

  defp reload_credential(user, server) do
    {:ok, credential} = MCP.get_credential_for_server(server.id, actor: user)
    credential
  end

  # Parse the `state` param out of the authorize URL the controller redirected to.
  defp state_from_authorize_redirect(conn, as) do
    location = redirected_to(conn, 302)
    assert String.starts_with?(location, "#{as.base}/authorize?")
    %URI{query: query} = URI.parse(location)
    URI.decode_query(query)["state"]
  end

  defp redirect_query(conn) do
    location = redirected_to(conn, 302)
    %URI{query: query} = URI.parse(location)
    {location, URI.decode_query(query || "")}
  end

  # The first dial to a freshly-opened MCP Bypass can exceed the tight test
  # init_timeout_ms; prime the pool so assertions see warm-client behavior.
  defp warm_up(server, attempts \\ 3) do
    case MCP.ClientManager.with_client(server, %{}, fn client ->
           MCP.Client.list_tools(client)
         end) do
      {:ok, _} -> :ok
      _ when attempts > 1 -> warm_up(server, attempts - 1)
      _ -> :ok
    end
  end

  # ===========================================================================
  # FULL HAPPY CHAIN — start → callback → executor Bearer dial
  # ===========================================================================

  describe "full chain: start → provider authorize → callback → MCP call with Bearer" do
    test "drives the whole flow and the executor dials with the minted Bearer", %{
      conn: conn,
      user: user
    } do
      as = start_as_server() |> stub_as_metadata() |> stub_register()
      mcp = start_mcp_server(as.base)

      # OAuth-only server: /token returns access + refresh + expires_in, NO
      # id_token (representative of OAuth-2.1 MCP servers, not OIDC providers).
      stub_token(as, 200, %{
        "access_token" => "e2e-access",
        "refresh_token" => "e2e-refresh",
        "token_type" => "Bearer",
        "expires_in" => 3600
      })

      server = oauth_server(user, mcp)
      warm_up(server)

      # --- leg 1: start --------------------------------------------------------
      # No stored client yet → DCR registers + persists it; State.issue stores the
      # PKCE verifier in Magus.Cache keyed by the `state` carried in the redirect.
      start_conn = get(conn, "/oauth/mcp/#{server.id}/start")
      state = state_from_authorize_redirect(start_conn, as)
      assert is_binary(state) and state != ""

      # The client was persisted by the DCR round-trip during `start`.
      assert reload_credential(user, server).oauth_client["client_id"] == "dcr-client-id"

      # --- leg 2: callback -----------------------------------------------------
      # Reuse the REAL issued `state`: State.verify consumes the verifier the
      # `start` leg cached, so the PKCE store is exercised end-to-end.
      cb_conn =
        get(conn, "/oauth/mcp/#{server.id}/callback", %{"code" => "auth-code", "state" => state})

      {location, params} = redirect_query(cb_conn)
      assert String.starts_with?(location, @settings_path)
      assert params["mcp_oauth"] == "connected"

      credential = reload_credential(user, server)
      assert credential.status == :connected
      assert credential.oauth_tokens["access_token"] == "e2e-access"
      assert credential.oauth_tokens["refresh_token"] == "e2e-refresh"
      # The DCR client survived the token store (not clobbered).
      assert credential.oauth_client["client_id"] == "dcr-client-id"

      # --- leg 3: executor dial ------------------------------------------------
      # The executor loads the just-persisted credential and dials the MCP Bypass.
      assert {:ok, result} = Executor.call(server, "echo", %{"text" => "hi"}, context(user))
      refute Map.has_key?(result, :error)
      assert %{"content" => [%{"type" => "text", "text" => "ok"}]} = result

      # The MCP server received the Bearer minted by the whole chain.
      assert "Bearer e2e-access" in Agent.get(mcp.state, & &1.bearers)
    end
  end

  # ===========================================================================
  # REFRESH-ON-401 — end to end across the controller-persisted credential
  # ===========================================================================

  describe "refresh-on-401 across the persisted credential" do
    # The executor's 401 refresh-retry has a focused unit test
    # (executor_oauth_test.exs "401 on the first dial ..."). This e2e version adds
    # the cross-module seam: the credential was persisted by the live controller
    # callback (not seeded directly), then the executor refreshes + re-persists the
    # rotated token and the retried dial succeeds.
    test "controller-stored token rejected once → executor refreshes, re-dials, re-persists", %{
      conn: conn,
      user: user
    } do
      as = start_as_server() |> stub_as_metadata() |> stub_register()
      # MCP server rejects the FIRST (stored) token; the refreshed token works.
      mcp = start_mcp_server(as.base, reject_stale: "stored-access")

      # /token is used twice: once by the callback's code exchange, once by the
      # executor's refresh. A single stub can't return two different bodies, so the
      # callback exchanges via a dedicated stub, then we re-stub /token for refresh.
      stub_token(as, 200, %{
        "access_token" => "stored-access",
        "refresh_token" => "stored-refresh",
        "token_type" => "Bearer",
        # NOT near expiry → preflight is skipped, so the stale token is dialed and
        # 401s, triggering the refresh-and-retry.
        "expires_in" => 3600
      })

      server = oauth_server(user, mcp)
      warm_up(server)

      start_conn = get(conn, "/oauth/mcp/#{server.id}/start")
      state = state_from_authorize_redirect(start_conn, as)

      cb_conn =
        get(conn, "/oauth/mcp/#{server.id}/callback", %{"code" => "auth-code", "state" => state})

      assert {_loc, %{"mcp_oauth" => "connected"}} = redirect_query(cb_conn)
      assert reload_credential(user, server).oauth_tokens["access_token"] == "stored-access"

      # Now the executor leg: re-stub /token so the refresh returns a NEW token the
      # MCP server accepts. Cache metadata so refresh resolves the token endpoint.
      server = cache_metadata(server, mcp, as, user)

      stub_token(as, 200, %{
        "access_token" => "refreshed-access",
        "refresh_token" => "refreshed-refresh",
        "token_type" => "Bearer",
        "expires_in" => 3600
      })

      assert {:ok, result} = Executor.call(server, "echo", %{}, context(user))
      refute Map.has_key?(result, :error)

      bearers = Agent.get(mcp.state, & &1.bearers)
      assert "Bearer stored-access" in bearers
      assert "Bearer refreshed-access" in bearers

      # The rotated token was re-persisted on the same credential the controller
      # wrote — the cross-module persistence seam.
      cred = reload_credential(user, server)
      assert cred.oauth_tokens["access_token"] == "refreshed-access"
      assert cred.oauth_tokens["refresh_token"] == "refreshed-refresh"
      assert cred.status == :connected
    end
  end

  # ===========================================================================
  # invalid_grant → :needs_auth — end to end
  # ===========================================================================

  describe "invalid_grant on refresh flips the persisted credential to :needs_auth" do
    test "connected credential, AS /token returns invalid_grant on refresh → needs_auth", %{
      conn: conn,
      user: user
    } do
      as = start_as_server() |> stub_as_metadata() |> stub_register()
      mcp = start_mcp_server(as.base)

      stub_token(as, 200, %{
        "access_token" => "doomed-access",
        "refresh_token" => "doomed-refresh",
        "token_type" => "Bearer",
        # Near expiry → the executor's PREFLIGHT refresh fires before any dial.
        "expires_in" => 10
      })

      server = oauth_server(user, mcp)
      warm_up(server)

      start_conn = get(conn, "/oauth/mcp/#{server.id}/start")
      state = state_from_authorize_redirect(start_conn, as)

      cb_conn =
        get(conn, "/oauth/mcp/#{server.id}/callback", %{"code" => "auth-code", "state" => state})

      assert {_loc, %{"mcp_oauth" => "connected"}} = redirect_query(cb_conn)
      assert reload_credential(user, server).status == :connected

      # Executor leg: refresh now fails invalid_grant. Cache metadata so refresh
      # resolves the token endpoint, then re-stub /token to reject.
      server = cache_metadata(server, mcp, as, user)
      stub_token(as, 400, %{"error" => "invalid_grant"})

      assert {:ok, %{error: msg}} = Executor.call(server, "echo", %{}, context(user))
      assert is_binary(msg)
      assert msg =~ "auth" or msg =~ "connect"

      # Re-read confirms the persisted credential flipped to :needs_auth, and (since
      # preflight failed before any dial) no Bearer reached the MCP server.
      assert reload_credential(user, server).status == :needs_auth
      assert Agent.get(mcp.state, & &1.bearers) == []
    end
  end

  # ===========================================================================
  # SECURITY PROPERTIES — asserted through the public start/callback/Flow seams.
  # ===========================================================================

  describe "security: SSRF rejection of a server-controlled OAuth URL" do
    # Covered at the Flow unit level (flow_test.exs "authorize_url/3 — SSRF
    # rejection"). This e2e version asserts the same property through the LIVE
    # controller `start` entry point: the redirect is the safe settings error, the
    # browser is NOT sent to a provider, and no credential/token is persisted.
    test "start with a metadata authorize_endpoint SafeUrl rejects → settings error, nothing stored",
         %{conn: conn, user: user} do
      as = start_as_server()
      mcp = start_mcp_server(as.base)

      server = oauth_server(user, mcp)

      # Pre-cache metadata whose authorize endpoint is a non-http(s) scheme that
      # SafeUrl rejects even under `allow_private_urls: true` (the Task 1/3
      # approach). A stored client lets resolution get past DCR so the SSRF gate on
      # the authorize endpoint is what aborts the flow.
      {:ok, server} =
        MCP.cache_server_oauth_metadata(
          server,
          %{
            oauth_metadata: %{
              "issuer" => as.base,
              "authorization_endpoint" => "file:///etc/passwd",
              "token_endpoint" => "#{as.base}/token",
              "registration_endpoint" => nil,
              "scopes_supported" => ["mcp"],
              "code_challenge_methods_supported" => ["S256"],
              "resource" => mcp.base,
              "authorization_servers" => [as.base]
            }
          },
          actor: user
        )

      {:ok, _} =
        MCP.store_oauth_client(
          %{mcp_server_id: server.id, oauth_client: %{"client_id" => "c"}},
          actor: user
        )

      conn = get(conn, "/oauth/mcp/#{server.id}/start")

      {location, params} = redirect_query(conn)
      # Aborted to settings with the discovery_failed code — NOT a provider redirect.
      assert String.starts_with?(location, @settings_path)
      refute String.contains?(location, "/authorize")
      assert params["mcp_oauth_error"] == "discovery_failed"

      # No tokens were minted/stored (the pre-stored client is the only state).
      assert reload_credential(user, server).oauth_tokens in [nil, %{}]
    end

    # Defense-in-depth seam: even bypassing the controller, Flow.authorize_url
    # itself re-validates the authorize endpoint before any oidcc call.
    test "Flow.authorize_url re-validates the authorize endpoint (SafeUrl aborts)", %{user: user} do
      as = start_as_server()
      mcp = start_mcp_server(as.base)
      server = oauth_server(user, mcp)

      {:ok, server} =
        MCP.cache_server_oauth_metadata(
          server,
          %{
            oauth_metadata: %{
              "issuer" => as.base,
              "authorization_endpoint" => "file:///etc/passwd",
              "token_endpoint" => "#{as.base}/token",
              "registration_endpoint" => nil,
              "scopes_supported" => ["mcp"],
              "code_challenge_methods_supported" => ["S256"],
              "resource" => mcp.base,
              "authorization_servers" => [as.base]
            }
          },
          actor: user
        )

      {:ok, _} =
        MCP.store_oauth_client(
          %{mcp_server_id: server.id, oauth_client: %{"client_id" => "c"}},
          actor: user
        )

      assert {:error, _reason} =
               Flow.authorize_url(server, user, "http://127.0.0.1:4000/oauth/mcp/cb")

      assert reload_credential(user, server).oauth_tokens in [nil, %{}]
    end
  end

  describe "security: HMAC state tamper" do
    # The controller test covers a garbled `state`; this asserts the same at the
    # live callback against a server reached through the full pipeline AND proves
    # the AS /token was never even called (so the tamper aborts before exchange).
    test "a garbled state is rejected, /token never hit, nothing stored", %{
      conn: conn,
      user: user
    } do
      as = start_as_server() |> stub_as_metadata()
      mcp = start_mcp_server(as.base)

      # If the (rejected) callback ever reached exchange, this would bump.
      stub_token(as, 200, %{"access_token" => "should-not-store"})

      server = oauth_server(user, mcp)

      conn =
        get(conn, "/oauth/mcp/#{server.id}/callback", %{
          "code" => "auth-code",
          "state" => "garbled-not-a-real-state"
        })

      {location, params} = redirect_query(conn)
      assert String.starts_with?(location, @settings_path)
      assert params["mcp_oauth_error"] == "invalid_state"

      # No exchange happened and no credential was written.
      assert Agent.get(as.token_counter, & &1) == 0
      cred = reload_credential(user, server)
      assert cred == nil or cred.oauth_tokens in [nil, %{}]
    end
  end

  describe "security: PKCE verifier required" do
    # A state whose HMAC is valid but whose cached verifier is absent (evicted /
    # never issued for it) must fail at State.verify (:no_verifier), which the
    # controller collapses to :invalid_state. This drives the State store seam that
    # the controller's "garbled state" case does not (that one fails the signature
    # check, never reaching the verifier lookup).
    test "valid-looking state with no cached verifier → rejected, /token never hit, nothing stored",
         %{conn: conn, user: user} do
      as = start_as_server() |> stub_as_metadata()
      mcp = start_mcp_server(as.base)
      stub_token(as, 200, %{"access_token" => "should-not-store"})

      server = oauth_server(user, mcp)

      # Forge a properly-signed state for {server, user} via the documented test
      # builder, but DO NOT issue it → no verifier is ever cached for this state.
      state = State.build_signed_state(server.id, user.id, System.system_time(:second))

      conn =
        get(conn, "/oauth/mcp/#{server.id}/callback", %{"code" => "auth-code", "state" => state})

      {location, params} = redirect_query(conn)
      assert String.starts_with?(location, @settings_path)
      assert params["mcp_oauth_error"] == "invalid_state"

      assert Agent.get(as.token_counter, & &1) == 0
      cred = reload_credential(user, server)
      assert cred == nil or cred.oauth_tokens in [nil, %{}]
    end
  end

  describe "security: cross-user state replay" do
    # A state issued for user A, replayed in user B's live session, must be
    # rejected by the controller's cross-binding assertion (session user == state
    # user). Asserted here through the live pipeline; nothing is stored under
    # either user.
    test "user A's state replayed in user B's session → rejected, nothing stored for either", %{
      conn: conn
    } do
      as = start_as_server() |> stub_as_metadata() |> stub_register()
      mcp = start_mcp_server(as.base)
      stub_token(as, 200, %{"access_token" => "should-not-store"})

      user_a = generate(user())
      user_b = generate(user())
      # The live session is user B.
      conn = log_in_user(conn, user_b)

      server = oauth_server(user_a, mcp)

      {:ok, _} =
        MCP.store_oauth_client(
          %{mcp_server_id: server.id, oauth_client: %{"client_id" => "x"}},
          actor: user_a
        )

      # Issue a genuinely-valid state (verifier cached) for user A.
      {state, _verifier} = State.issue(server.id, user_a.id)

      conn =
        get(conn, "/oauth/mcp/#{server.id}/callback", %{"code" => "auth-code", "state" => state})

      {location, params} = redirect_query(conn)
      assert String.starts_with?(location, @settings_path)
      assert params["mcp_oauth_error"] == "invalid_state"

      # No exchange, and no tokens stored under A. (B has no credential for A's
      # server; the callback never loaded it.)
      assert Agent.get(as.token_counter, & &1) == 0
      assert reload_credential(user_a, server).oauth_tokens in [nil, %{}]
    end
  end

  describe "security: unauthorized server" do
    # A user cannot START a flow for a server they cannot read: the load is
    # actor-scoped and a forbidden server collapses to the same redirect as
    # not-found (no enumeration). No provider redirect, nothing stored.
    test "starting a flow for another user's server is denied (no provider redirect)", %{
      conn: conn
    } do
      as = start_as_server() |> stub_as_metadata() |> stub_register()
      mcp = start_mcp_server(as.base)

      # Server owned by a DIFFERENT user — the session user cannot read it.
      other = generate(user())
      server = oauth_server(other, mcp)

      conn = get(conn, "/oauth/mcp/#{server.id}/start")

      {location, params} = redirect_query(conn)
      assert String.starts_with?(location, @settings_path)
      refute String.contains?(location, "/authorize")
      assert params["mcp_oauth_error"] == "server_unavailable"

      # The owner's credential was not created/mutated by the denied attempt.
      assert reload_credential(other, server) in [nil] or
               reload_credential(other, server).oauth_tokens in [nil, %{}]
    end
  end
end
