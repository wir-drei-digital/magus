defmodule Magus.MCP.Auth.DiscoveryTest do
  @moduledoc """
  Drives `Magus.MCP.Auth.Discovery.ensure_metadata/2` against Bypass-backed
  mock OAuth/OIDC authorization servers (no live network, no real provider).

  Covers the four required cases:

    * RFC 9728 protected-resource metadata -> RFC 8414 AS metadata happy path,
      with the extracted endpoints persisted on `Server.oauth_metadata`.
    * cached short-circuit: a populated `oauth_metadata` skips all HTTP.
    * SSRF rejection: a bad URL inside discovered metadata aborts discovery and
      does NOT cache partial junk.
    * OIDC path: an issuer that publishes `/.well-known/openid-configuration` is
      parsed (through the oidcc decode path) into the same normalized map shape.
  """
  use Magus.ResourceCase, async: false

  alias Magus.MCP
  alias Magus.MCP.Auth.Discovery

  @moduletag :mcp_integration

  setup do
    user = generate(user())
    %{user: user}
  end

  # Build a server pointed at a Bypass instance. `oauth_metadata` starts empty.
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

  # Stub the RFC 9728 protected-resource metadata document. Points at one or
  # more authorization servers (each its own base URL).
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

  # Stub the RFC 8414 OAuth authorization-server metadata document.
  defp stub_as_metadata(bypass, issuer, overrides \\ %{}) do
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

  describe "ensure_metadata/2 — RFC 9728 + RFC 8414 happy path" do
    test "discovers, extracts, and caches AS endpoints on the server", %{user: user} do
      bypass = Bypass.open()
      base = "http://127.0.0.1:#{bypass.port}"

      stub_protected_resource(bypass, base, [base])
      stub_as_metadata(bypass, base)

      server = oauth_server(user, bypass)

      assert {:ok, metadata} = Discovery.ensure_metadata(server, user)

      assert metadata["issuer"] == base
      assert metadata["authorization_endpoint"] == "#{base}/authorize"
      assert metadata["token_endpoint"] == "#{base}/token"
      assert metadata["registration_endpoint"] == "#{base}/register"
      assert "mcp" in metadata["scopes_supported"]
      assert metadata["code_challenge_methods_supported"] == ["S256"]

      # Persisted: re-read the server and assert the cache is on the row.
      {:ok, reloaded} = MCP.get_server(server.id, actor: user)
      assert reloaded.oauth_metadata["issuer"] == base
      assert reloaded.oauth_metadata["authorization_endpoint"] == "#{base}/authorize"
      assert reloaded.oauth_metadata["token_endpoint"] == "#{base}/token"
    end
  end

  describe "ensure_metadata/2 — cached short-circuit" do
    test "returns the cached metadata without any HTTP when already populated", %{user: user} do
      # Bypass with NO stubs: any HTTP request would fail the test (Bypass
      # returns 500 for unstubbed routes, which discovery would surface as an
      # error). A cached short-circuit must not touch it at all.
      bypass = Bypass.open()
      Bypass.down(bypass)

      cached = %{
        "issuer" => "https://cached.example.com",
        "authorization_endpoint" => "https://cached.example.com/authorize",
        "token_endpoint" => "https://cached.example.com/token"
      }

      server = oauth_server(user, bypass)

      {:ok, server} =
        MCP.cache_server_oauth_metadata(server, %{oauth_metadata: cached}, actor: user)

      assert {:ok, ^cached} = Discovery.ensure_metadata(server, user)
    end
  end

  describe "ensure_metadata/2 — SSRF rejection" do
    test "a bad URL in discovered metadata aborts and caches nothing", %{user: user} do
      bypass = Bypass.open()
      base = "http://127.0.0.1:#{bypass.port}"

      # The protected-resource doc points the AS at a non-http(s) scheme, which
      # SafeUrl rejects even under the test `allow_private_urls: true` config.
      stub_protected_resource(bypass, base, ["file:///etc/passwd"])

      server = oauth_server(user, bypass)

      assert {:error, _reason} = Discovery.ensure_metadata(server, user)

      # No partial junk cached.
      {:ok, reloaded} = MCP.get_server(server.id, actor: user)
      assert reloaded.oauth_metadata == %{}
    end
  end

  describe "ensure_metadata/2 — OIDC discovery path" do
    test "parses an openid-configuration document into the normalized shape", %{user: user} do
      bypass = Bypass.open()
      base = "http://127.0.0.1:#{bypass.port}"

      # Protected-resource doc points at an AS that ONLY serves OIDC discovery
      # (no RFC 8414 oauth-authorization-server doc).
      stub_protected_resource(bypass, base, [base])

      # 404 the RFC 8414 endpoint so discovery falls back to OIDC discovery.
      Bypass.stub(bypass, "GET", "/.well-known/oauth-authorization-server", fn conn ->
        Plug.Conn.resp(conn, 404, "not found")
      end)

      # A full OIDC discovery document with all decode_configuration-required
      # fields populated.
      oidc_doc = %{
        "issuer" => base,
        "authorization_endpoint" => "#{base}/authorize",
        "token_endpoint" => "#{base}/token",
        "registration_endpoint" => "#{base}/register",
        "jwks_uri" => "#{base}/jwks",
        "scopes_supported" => ["openid", "profile", "mcp"],
        "response_types_supported" => ["code"],
        "subject_types_supported" => ["public"],
        "id_token_signing_alg_values_supported" => ["RS256"],
        "grant_types_supported" => ["authorization_code", "refresh_token"],
        "code_challenge_methods_supported" => ["S256"]
      }

      Bypass.stub(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(oidc_doc))
      end)

      server = oauth_server(user, bypass)

      assert {:ok, metadata} = Discovery.ensure_metadata(server, user)

      assert metadata["issuer"] == base
      assert metadata["authorization_endpoint"] == "#{base}/authorize"
      assert metadata["token_endpoint"] == "#{base}/token"
      assert metadata["registration_endpoint"] == "#{base}/register"
      assert "mcp" in metadata["scopes_supported"]
      assert metadata["code_challenge_methods_supported"] == ["S256"]

      {:ok, reloaded} = MCP.get_server(server.id, actor: user)
      assert reloaded.oauth_metadata["issuer"] == base
    end
  end
end
