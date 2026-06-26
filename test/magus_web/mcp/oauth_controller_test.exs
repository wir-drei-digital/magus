defmodule MagusWeb.MCP.OAuthControllerTest do
  @moduledoc """
  Drives the browser-redirect OAuth controller `MagusWeb.MCP.OAuthController`
  (`start/2` + `callback/2`) end-to-end: a real logged-in session, real
  `Magus.MCP.Auth.Flow` + `Magus.MCP.Auth.State` + `Magus.Cache`, a real DB, and
  a Bypass-backed mock OAuth authorization server (mirrors `Flow`'s test). No
  mocks — the only stand-in is the network AS.

  ## Query-param contract (read by Task 6's SPA settings page)

  Every branch redirects to `/next/settings/mcp-servers` with exactly one of:

    * `?mcp_oauth=connected`              — tokens stored, status :connected
    * `?mcp_oauth_error=<code>` where <code> is one of the fixed safe set:
      `client_id_required | discovery_failed | not_oauth | invalid_state |
       denied | exchange_failed | server_unavailable`

  No token / refresh_token / code / verifier ever appears in any redirect.
  """
  use MagusWeb.ConnCase, async: false

  import Magus.Generators

  alias Magus.MCP
  alias Magus.MCP.Auth.State

  @moduletag :mcp_integration

  @settings_path "/next/settings/mcp-servers"

  # Mirror the controller's fixed, non-secret error-code set (the SPA contract).
  @error_codes ~w(client_id_required discovery_failed not_oauth invalid_state denied exchange_failed server_unavailable)

  setup %{conn: conn} do
    user = generate(user())
    %{conn: log_in_user(conn, user), user: user}
  end

  # ConnCase doesn't import a session-login helper (it lives in LiveViewCase), so
  # establish the session the same way: a real session token via
  # AshAuthentication, which the :browser pipeline's :load_from_session reads into
  # conn.assigns.current_user.
  defp log_in_user(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # ---------------------------------------------------------------------------
  # Server + Bypass helpers (mirror Magus.MCP.Auth.FlowTest)
  # ---------------------------------------------------------------------------

  defp oauth_server(actor, bypass, attrs \\ %{}) do
    {:ok, server} =
      MCP.create_server(
        Map.merge(
          %{
            name: "OAuthSvc",
            handle: "oauthsvc#{System.unique_integer([:positive])}",
            url: "http://127.0.0.1:#{bypass.port}",
            mcp_path: "/mcp",
            auth_type: :oauth
          },
          attrs
        ),
        actor: actor
      )

    server
  end

  defp stub_protected_resource(bypass, resource_url, authorization_servers) do
    Bypass.stub(bypass, "GET", "/.well-known/oauth-protected-resource", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "resource" => resource_url,
          "authorization_servers" => authorization_servers
        })
      )
    end)
  end

  defp stub_as_metadata(bypass, issuer, overrides) do
    doc =
      Map.merge(
        %{
          "issuer" => issuer,
          "authorization_endpoint" => "#{issuer}/authorize",
          "token_endpoint" => "#{issuer}/token",
          "registration_endpoint" => "#{issuer}/register",
          "scopes_supported" => ["openid", "profile", "mcp"],
          "response_types_supported" => ["code"],
          "grant_types_supported" => ["authorization_code", "refresh_token"],
          "code_challenge_methods_supported" => ["S256"]
        },
        overrides
      )

    Bypass.stub(bypass, "GET", "/.well-known/oauth-authorization-server", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(doc))
    end)
  end

  defp stub_discovery(bypass, as_overrides \\ %{}) do
    base = "http://127.0.0.1:#{bypass.port}"
    stub_protected_resource(bypass, base, [base])
    stub_as_metadata(bypass, base, as_overrides)
    base
  end

  defp stub_register(bypass, client_id \\ "dcr-client-id") do
    Bypass.stub(bypass, "POST", "/register", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(201, Jason.encode!(%{"client_id" => client_id}))
    end)
  end

  defp stub_token(bypass, status, body) do
    Bypass.stub(bypass, "POST", "/token", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)
  end

  # Pull the single query param value off a redirect Location, regardless of path.
  defp redirect_query(conn) do
    location = redirected_to(conn, 302)
    %URI{query: query} = URI.parse(location)
    {location, URI.decode_query(query || "")}
  end

  # ---------------------------------------------------------------------------
  # start/2
  # ---------------------------------------------------------------------------

  describe "GET /oauth/mcp/:server_id/start" do
    test "redirects the browser to the provider authorize URL with state", %{
      conn: conn,
      user: user
    } do
      bypass = Bypass.open()
      base = stub_discovery(bypass)
      stub_register(bypass)

      server = oauth_server(user, bypass)

      conn = get(conn, "/oauth/mcp/#{server.id}/start")

      location = redirected_to(conn, 302)
      # Redirects to the EXTERNAL provider, not back to settings.
      assert String.starts_with?(location, "#{base}/authorize?")

      %URI{query: query} = URI.parse(location)
      params = URI.decode_query(query)
      assert params["state"] != nil and params["state"] != ""
      assert params["code_challenge_method"] == "S256"
      assert params["client_id"] == "dcr-client-id"
    end

    test "a server the user cannot read redirects to settings with an error (no enumeration leak)",
         %{conn: conn} do
      bypass = Bypass.open()
      stub_discovery(bypass)
      stub_register(bypass)

      # Server owned by a DIFFERENT user — the session user cannot read it.
      other = generate(user())
      server = oauth_server(other, bypass)

      conn = get(conn, "/oauth/mcp/#{server.id}/start")

      {location, params} = redirect_query(conn)
      assert String.starts_with?(location, @settings_path)
      # NOT redirected to a provider; an actionable, non-secret error code.
      refute String.contains?(location, "/authorize")
      assert params["mcp_oauth_error"] != nil
    end

    test "a non-oauth server redirects with mcp_oauth_error=not_oauth", %{conn: conn, user: user} do
      bypass = Bypass.open()
      server = oauth_server(user, bypass, %{auth_type: :none})

      conn = get(conn, "/oauth/mcp/#{server.id}/start")

      {location, params} = redirect_query(conn)
      assert String.starts_with?(location, @settings_path)
      assert params["mcp_oauth_error"] == "not_oauth"
    end
  end

  # ---------------------------------------------------------------------------
  # callback/2 — success
  # ---------------------------------------------------------------------------

  describe "GET /oauth/mcp/:server_id/callback — success" do
    test "stores tokens, marks connected, preserves oauth_client, redirects connected", %{
      conn: conn,
      user: user
    } do
      bypass = Bypass.open()
      stub_discovery(bypass)

      stub_token(bypass, 200, %{
        "access_token" => "access-xyz",
        "refresh_token" => "refresh-xyz",
        "token_type" => "Bearer",
        "expires_in" => 3600
      })

      server = oauth_server(user, bypass)

      # authorize_url would have persisted the client; store it directly so the
      # exchange can find it. This is the value that must NOT be clobbered.
      {:ok, _} =
        MCP.store_oauth_client(
          %{mcp_server_id: server.id, oauth_client: %{"client_id" => "cb-client"}},
          actor: user
        )

      # Issue a real state so the verifier is cached and verify/1 succeeds.
      {state, _verifier} = State.issue(server.id, user.id)

      conn =
        get(conn, "/oauth/mcp/#{server.id}/callback", %{
          "code" => "auth-code",
          "state" => state
        })

      {location, params} = redirect_query(conn)
      assert String.starts_with?(location, @settings_path)
      assert params["mcp_oauth"] == "connected"

      {:ok, credential} = MCP.get_credential_for_server(server.id, actor: user)
      assert credential.status == :connected
      assert credential.oauth_tokens["access_token"] == "access-xyz"
      # The persisted client survived the token store (not clobbered to nil).
      assert credential.oauth_client["client_id"] == "cb-client"
    end
  end

  # ---------------------------------------------------------------------------
  # callback/2 — security / failure
  # ---------------------------------------------------------------------------

  describe "GET /oauth/mcp/:server_id/callback — rejections" do
    test "a tampered state is rejected and stores nothing", %{conn: conn, user: user} do
      bypass = Bypass.open()
      stub_discovery(bypass)
      stub_token(bypass, 200, %{"access_token" => "should-not-store"})

      server = oauth_server(user, bypass)

      conn =
        get(conn, "/oauth/mcp/#{server.id}/callback", %{
          "code" => "auth-code",
          "state" => "garbled-not-a-real-state"
        })

      {location, params} = redirect_query(conn)
      assert String.starts_with?(location, @settings_path)
      assert params["mcp_oauth_error"] == "invalid_state"

      # No credential was written.
      {:ok, credential} = MCP.get_credential_for_server(server.id, actor: user)
      assert credential == nil or credential.oauth_tokens in [nil, %{}]
    end

    test "a callback whose session user != state user is rejected, stores nothing", %{conn: conn} do
      bypass = Bypass.open()
      stub_discovery(bypass)
      stub_token(bypass, 200, %{"access_token" => "should-not-store"})

      # The session is user B (from setup). Issue a valid state for a DIFFERENT
      # user A. The cross-binding assertion must reject it.
      session_user_b = generate(user())
      conn = log_in_user(conn, session_user_b)

      user_a = generate(user())
      server = oauth_server(user_a, bypass)

      {:ok, _} =
        MCP.store_oauth_client(
          %{mcp_server_id: server.id, oauth_client: %{"client_id" => "x"}},
          actor: user_a
        )

      {state, _verifier} = State.issue(server.id, user_a.id)

      conn =
        get(conn, "/oauth/mcp/#{server.id}/callback", %{
          "code" => "auth-code",
          "state" => state
        })

      {location, params} = redirect_query(conn)
      assert String.starts_with?(location, @settings_path)
      assert params["mcp_oauth_error"] == "invalid_state"

      # No tokens stored on user A's credential.
      {:ok, credential} = MCP.get_credential_for_server(server.id, actor: user_a)
      assert credential.oauth_tokens in [nil, %{}]
    end

    test "a provider error (?error=access_denied) redirects with error, status unchanged", %{
      conn: conn,
      user: user
    } do
      bypass = Bypass.open()
      stub_discovery(bypass)

      server = oauth_server(user, bypass)

      conn =
        get(conn, "/oauth/mcp/#{server.id}/callback", %{"error" => "access_denied"})

      {location, params} = redirect_query(conn)
      assert String.starts_with?(location, @settings_path)
      assert params["mcp_oauth_error"] == "denied"

      # Status not flipped to connected.
      {:ok, credential} = MCP.get_credential_for_server(server.id, actor: user)
      assert credential == nil or credential.status != :connected
    end

    test "an unexpected persist failure redirects (never a raw 500)", %{conn: conn, user: user} do
      bypass = Bypass.open()
      stub_discovery(bypass)

      # Force `store_oauth_tokens` to fail at the DB layer on an otherwise-valid
      # callback: an `expires_in` so large that `Flow.exchange_code` derives an
      # `oauth_expires_at` past Postgres' timestamp range (year 294276), so the
      # INSERT errors with `{:error, %Ash.Error.Unknown{}}`. That struct does NOT
      # match the callback's `:invalid_state | :server_unavailable |
      # :exchange_failed` clauses — before the fix it raised `WithClauseError`
      # (an unhandled 500); now `persist_tokens/3` normalizes any persist error to
      # `:exchange_failed` so every branch still ends in a redirect.
      stub_token(bypass, 200, %{
        "access_token" => "access-xyz",
        "refresh_token" => "refresh-xyz",
        "token_type" => "Bearer",
        "expires_in" => 9_999_999_999_999
      })

      server = oauth_server(user, bypass)

      {:ok, _} =
        MCP.store_oauth_client(
          %{mcp_server_id: server.id, oauth_client: %{"client_id" => "cb-client"}},
          actor: user
        )

      {state, _verifier} = State.issue(server.id, user.id)

      conn =
        get(conn, "/oauth/mcp/#{server.id}/callback", %{
          "code" => "auth-code",
          "state" => state
        })

      # A 302 redirect to the SPA settings page with a non-secret error code —
      # NOT a raised error / 500.
      {location, params} = redirect_query(conn)
      assert String.starts_with?(location, @settings_path)
      assert params["mcp_oauth_error"] in @error_codes
      assert params["mcp_oauth_error"] == "exchange_failed"

      # The persist failed, so the credential never flipped to :connected and no
      # tokens leaked into storage.
      {:ok, credential} = MCP.get_credential_for_server(server.id, actor: user)
      assert credential == nil or credential.status != :connected
      assert credential == nil or credential.oauth_tokens in [nil, %{}]
    end
  end
end
