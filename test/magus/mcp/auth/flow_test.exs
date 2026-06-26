defmodule Magus.MCP.Auth.FlowTest do
  @moduledoc """
  Drives `Magus.MCP.Auth.Flow` (authorize URL build, code exchange, refresh, and
  dynamic client registration) against a Bypass-backed mock OAuth authorization
  server. No live network, real oidcc, real `Magus.Cache`/DB.

  The Bypass instance serves:

    * RFC 9728 protected-resource metadata + RFC 8414 AS metadata (so the
      `Discovery.ensure_metadata/2` step the flow calls succeeds), and
    * `/token` (code exchange + refresh) and `/register` (DCR).

  Covers (per the Task 3 brief):

    * authorize_url: URL carries PKCE S256 (`code_challenge` + method), `state`,
      `redirect_uri`, and the RFC 8707 `resource` param; DCR registers + persists
      `oauth_client` on the credential.
    * authorize_url with a pre-stored `oauth_client`: does NOT call /register.
    * authorize_url with no client + no registration endpoint: `:client_id_required`.
    * exchange_code: returns access/refresh tokens + a computed `expires_at`.
    * refresh: rotation (new refresh token carried), no-rotation (old carried
      forward, never nil), and `invalid_grant` surfaced distinctly.
    * SSRF: an authorize/token endpoint SafeUrl rejects aborts before any oidcc
      call.
  """
  use Magus.ResourceCase, async: false

  alias Magus.MCP
  alias Magus.MCP.Auth.Flow

  @moduletag :mcp_integration

  @redirect_uri "http://127.0.0.1:4000/oauth/mcp/callback"

  setup do
    user = generate(user())
    %{user: user}
  end

  # ---------------------------------------------------------------------------
  # Server + Bypass helpers
  # ---------------------------------------------------------------------------

  defp oauth_server(user, bypass, attrs \\ %{}) do
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
        actor: user
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

  # Serve discovery (protected-resource + AS metadata) at the Bypass base. By
  # default it advertises a /register endpoint.
  defp stub_discovery(bypass, as_overrides \\ %{}) do
    base = "http://127.0.0.1:#{bypass.port}"
    stub_protected_resource(bypass, base, [base])
    stub_as_metadata(bypass, base, as_overrides)
    base
  end

  # RFC 7591 dynamic client registration: return a client_id (public client, no
  # secret). Counts hits via an Agent so a test can assert it was/ wasn't called.
  defp stub_register(bypass, counter, client_id \\ "dcr-client-id") do
    Bypass.stub(bypass, "POST", "/register", fn conn ->
      Agent.update(counter, &(&1 + 1))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(201, Jason.encode!(%{"client_id" => client_id}))
    end)
  end

  # RFC 6749 token endpoint: returns the provided JSON body (string-keyed map) at
  # `status`. Content-type MUST be application/json so oidcc decodes the body.
  defp stub_token(bypass, status, body) do
    Bypass.stub(bypass, "POST", "/token", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)
  end

  # ExUnit-supervised hit counter (auto torn down at test end). Unique id so
  # multiple counters can coexist within a test.
  defp new_counter do
    start_supervised!(
      Supervisor.child_spec({Agent, fn -> 0 end},
        id: {:flow_test_counter, System.unique_integer([:positive])}
      )
    )
  end

  # ---------------------------------------------------------------------------
  # authorize_url
  # ---------------------------------------------------------------------------

  describe "authorize_url/3 — DCR path" do
    test "builds a URL with PKCE S256, state, redirect_uri, resource; persists oauth_client",
         %{user: user} do
      bypass = Bypass.open()
      base = stub_discovery(bypass)
      counter = new_counter()
      stub_register(bypass, counter)

      server = oauth_server(user, bypass)

      assert {:ok, url} = Flow.authorize_url(server, user, @redirect_uri)

      %URI{query: query} = URI.parse(url)
      params = URI.decode_query(query)

      assert params["code_challenge_method"] == "S256"
      assert is_binary(params["code_challenge"]) and params["code_challenge"] != ""
      assert params["state"] != nil and params["state"] != ""
      assert params["redirect_uri"] == @redirect_uri
      # RFC 8707 resource indicator = the RFC 9728 canonical resource id.
      assert params["resource"] == base
      assert params["client_id"] == "dcr-client-id"
      assert String.starts_with?(url, "#{base}/authorize?")

      # DCR was called exactly once.
      assert Agent.get(counter, & &1) == 1

      # oauth_client persisted on the per-user credential.
      {:ok, credential} = MCP.get_credential_for_server(server.id, actor: user)
      assert credential.oauth_client["client_id"] == "dcr-client-id"
      assert credential.auth_kind == :oauth
    end
  end

  describe "authorize_url/3 — pre-stored client" do
    test "uses the stored oauth_client and does NOT call /register", %{user: user} do
      bypass = Bypass.open()
      base = stub_discovery(bypass)
      counter = new_counter()
      stub_register(bypass, counter)

      server = oauth_server(user, bypass)

      # Pre-store an oauth_client so the flow skips DCR.
      {:ok, _} =
        MCP.store_oauth_client(
          %{mcp_server_id: server.id, oauth_client: %{"client_id" => "preexisting-client"}},
          actor: user
        )

      assert {:ok, url} = Flow.authorize_url(server, user, @redirect_uri)

      params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert params["client_id"] == "preexisting-client"
      assert String.starts_with?(url, "#{base}/authorize?")

      # /register never hit.
      assert Agent.get(counter, & &1) == 0
    end
  end

  describe "authorize_url/3 — no client + no registration endpoint" do
    test "returns {:error, :client_id_required}", %{user: user} do
      bypass = Bypass.open()
      # AS metadata advertises NO registration_endpoint.
      stub_discovery(bypass, %{"registration_endpoint" => nil})

      server = oauth_server(user, bypass)

      assert {:error, :client_id_required} = Flow.authorize_url(server, user, @redirect_uri)
    end
  end

  describe "authorize_url/3 — SSRF rejection" do
    test "a SafeUrl-rejected authorize endpoint aborts with an error", %{user: user} do
      bypass = Bypass.open()
      base = "http://127.0.0.1:#{bypass.port}"
      stub_protected_resource(bypass, base, [base])

      # AS metadata with a registration endpoint + a client so we get past client
      # resolution, but inject metadata directly so the authorize endpoint is a
      # scheme SafeUrl rejects. We pre-cache metadata on the server to bypass
      # discovery's own SSRF gate (defense-in-depth: the flow must re-validate).
      server = oauth_server(user, bypass)

      {:ok, server} =
        MCP.cache_server_oauth_metadata(
          server,
          %{
            oauth_metadata: %{
              "issuer" => base,
              "authorization_endpoint" => "file:///etc/passwd",
              "token_endpoint" => "#{base}/token",
              "registration_endpoint" => nil,
              "scopes_supported" => ["mcp"],
              "code_challenge_methods_supported" => ["S256"],
              "resource" => base,
              "authorization_servers" => [base]
            }
          },
          actor: user
        )

      {:ok, _} =
        MCP.store_oauth_client(
          %{mcp_server_id: server.id, oauth_client: %{"client_id" => "c"}},
          actor: user
        )

      assert {:error, _reason} = Flow.authorize_url(server, user, @redirect_uri)
    end
  end

  # ---------------------------------------------------------------------------
  # exchange_code
  # ---------------------------------------------------------------------------

  describe "exchange_code/5" do
    test "returns access/refresh tokens and a computed expires_at", %{user: user} do
      bypass = Bypass.open()
      stub_discovery(bypass)

      stub_token(bypass, 200, %{
        "access_token" => "access-123",
        "refresh_token" => "refresh-123",
        "token_type" => "Bearer",
        "expires_in" => 3600
      })

      server = oauth_server(user, bypass)

      # Stored client (authorize_url would have persisted it; store directly so
      # this test does not depend on the DCR round-trip).
      {:ok, _} =
        MCP.store_oauth_client(
          %{mcp_server_id: server.id, oauth_client: %{"client_id" => "exchange-client"}},
          actor: user
        )

      before = DateTime.utc_now()

      assert {:ok, tokens} =
               Flow.exchange_code(server, user, "auth-code", "the-verifier", @redirect_uri)

      assert tokens.access_token == "access-123"
      assert tokens.refresh_token == "refresh-123"
      assert %DateTime{} = tokens.expires_at
      # ~3600s in the future (allow generous slack for test timing).
      diff = DateTime.diff(tokens.expires_at, before, :second)
      assert diff >= 3590 and diff <= 3700
    end
  end

  # ---------------------------------------------------------------------------
  # refresh
  # ---------------------------------------------------------------------------

  describe "refresh/2" do
    setup %{user: user} do
      bypass = Bypass.open()
      base = stub_discovery(bypass)
      server = oauth_server(user, bypass)

      # Seed a stored client + a refresh token directly (refresh/2 reads both off
      # the credential; no authorize round-trip needed to set this up).
      {:ok, credential} =
        MCP.store_oauth_tokens(
          %{
            mcp_server_id: server.id,
            oauth_tokens: %{"access_token" => "old-access", "refresh_token" => "old-refresh"},
            oauth_expires_at: DateTime.utc_now(),
            oauth_client: %{"client_id" => "dcr-client-id"}
          },
          actor: user
        )

      {:ok, server} = MCP.get_server(server.id, actor: user)
      %{bypass: bypass, base: base, server: server, credential: credential}
    end

    test "rotation: a new refresh_token is carried forward", ctx do
      stub_token(ctx.bypass, 200, %{
        "access_token" => "new-access",
        "refresh_token" => "rotated-refresh",
        "token_type" => "Bearer",
        "expires_in" => 1800
      })

      assert {:ok, tokens} = Flow.refresh(ctx.server, ctx.credential)
      assert tokens.access_token == "new-access"
      assert tokens.refresh_token == "rotated-refresh"
      assert %DateTime{} = tokens.expires_at
    end

    test "the refresh POST carries grant_type, resource, and the public client_id", ctx do
      Bypass.stub(ctx.bypass, "POST", "/token", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(raw)

        assert params["grant_type"] == "refresh_token"
        assert params["refresh_token"] == "old-refresh"
        # RFC 8707 resource indicator = the RFC 9728 canonical id (the base).
        assert params["resource"] == ctx.base
        # Public client (no secret) must send client_id in the body (RFC 6749 §3.2.1).
        assert params["client_id"] == "dcr-client-id"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"access_token" => "a", "token_type" => "Bearer", "expires_in" => 60})
        )
      end)

      assert {:ok, %{access_token: "a"}} = Flow.refresh(ctx.server, ctx.credential)
    end

    test "no rotation: the old refresh_token is carried forward (never nil)", ctx do
      stub_token(ctx.bypass, 200, %{
        "access_token" => "new-access",
        "token_type" => "Bearer",
        "expires_in" => 1800
      })

      assert {:ok, tokens} = Flow.refresh(ctx.server, ctx.credential)
      assert tokens.access_token == "new-access"
      # AS omitted refresh_token -> carry the stored one forward, NOT nil.
      assert tokens.refresh_token == "old-refresh"
    end

    test "invalid_grant: a 400 invalid_grant surfaces as {:error, :invalid_grant}", ctx do
      stub_token(ctx.bypass, 400, %{"error" => "invalid_grant"})

      assert {:error, :invalid_grant} = Flow.refresh(ctx.server, ctx.credential)
    end

    test "SSRF: a SafeUrl-rejected token endpoint aborts before any oidcc call", %{user: user} do
      bypass = Bypass.open()
      base = "http://127.0.0.1:#{bypass.port}"
      server = oauth_server(user, bypass)

      {:ok, server} =
        MCP.cache_server_oauth_metadata(
          server,
          %{
            oauth_metadata: %{
              "issuer" => base,
              "authorization_endpoint" => "#{base}/authorize",
              "token_endpoint" => "file:///etc/passwd",
              "registration_endpoint" => nil,
              "scopes_supported" => ["mcp"],
              "code_challenge_methods_supported" => ["S256"],
              "resource" => base,
              "authorization_servers" => [base]
            }
          },
          actor: user
        )

      {:ok, credential} =
        MCP.store_oauth_tokens(
          %{
            mcp_server_id: server.id,
            oauth_tokens: %{"access_token" => "a", "refresh_token" => "r"},
            oauth_expires_at: DateTime.utc_now(),
            oauth_client: %{"client_id" => "c"}
          },
          actor: user
        )

      assert {:error, _reason} = Flow.refresh(server, credential)
    end

    test "a confidential client sends HTTP Basic auth (not client_id in the body)", %{user: user} do
      bypass = Bypass.open()
      base = stub_discovery(bypass)
      server = oauth_server(user, bypass)

      {:ok, credential} =
        MCP.store_oauth_tokens(
          %{
            mcp_server_id: server.id,
            oauth_tokens: %{"access_token" => "a", "refresh_token" => "old-refresh"},
            oauth_expires_at: DateTime.utc_now(),
            oauth_client: %{"client_id" => "conf-client", "client_secret" => "s3cret"}
          },
          actor: user
        )

      {:ok, server} = MCP.get_server(server.id, actor: user)

      Bypass.stub(bypass, "POST", "/token", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        params = URI.decode_query(raw)

        # Confidential client authenticates via Basic, NOT a body client_id.
        assert {"authorization", "Basic " <> encoded} =
                 List.keyfind(conn.req_headers, "authorization", 0)

        assert Base.decode64!(encoded) == "conf-client:s3cret"
        refute Map.has_key?(params, "client_id")
        assert params["resource"] == base

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "access_token" => "new-a",
            "token_type" => "Bearer",
            "expires_in" => 60
          })
        )
      end)

      assert {:ok, %{access_token: "new-a"}} = Flow.refresh(server, credential)
    end
  end
end
