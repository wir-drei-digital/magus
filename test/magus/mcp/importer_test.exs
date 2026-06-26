defmodule Magus.MCP.ImporterTest do
  use Magus.ResourceCase, async: false

  alias Magus.MCP
  alias Magus.MCP.{Importer, RegistryEntry}

  @moduletag :mcp_integration

  describe "split_url/1" do
    test "splits a full endpoint into origin + path" do
      assert {"https://srv.example", "/mcp"} = Importer.split_url("https://srv.example/mcp")
    end

    test "preserves a non-default port and query string" do
      assert {"https://srv.example:8443", "/path/mcp?x=1"} =
               Importer.split_url("https://srv.example:8443/path/mcp?x=1")
    end

    test "drops the default https port and tolerates a bare origin" do
      assert {"https://srv.example", ""} = Importer.split_url("https://srv.example")
      assert {"https://srv.example", "/mcp"} = Importer.split_url("https://srv.example:443/mcp")
    end
  end

  describe "unique_handle/3" do
    test "slugifies the display name", %{} do
      user = generate(user())
      assert {:ok, "github_mcp"} = Importer.unique_handle("GitHub MCP", nil, user)
    end

    test "suffixes on collision within the scope" do
      user = generate(user())

      {:ok, _} =
        MCP.create_server(%{name: "X", handle: "github", url: "https://x.example"}, actor: user)

      assert {:ok, "github_2"} = Importer.unique_handle("GitHub", nil, user)
    end
  end

  describe "import_entry/3" do
    setup do
      bypass =
        Magus.MCP.MockServer.start(
          tools: [%{"name" => "echo", "description" => "Echo", "inputSchema" => %{}}]
        )

      %{user: generate(user()), bypass: bypass}
    end

    defp entry(bypass, opts \\ []) do
      %RegistryEntry{
        registry_name: opts[:registry_name] || "io.github.acme/widget",
        display_name: opts[:display_name] || "Widget",
        description: "A widget server",
        version: "1.2.3",
        repository_url: "https://github.com/acme/widget",
        transport: :streamable_http,
        endpoint_url: "http://127.0.0.1:#{bypass.port}/mcp",
        auth_type: opts[:auth_type] || :none,
        required_headers: opts[:required_headers] || []
      }
    end

    test "creates a server, records provenance, and discovers tools", %{
      user: user,
      bypass: bypass
    } do
      assert {:ok, result} = Importer.import_entry(entry(bypass), [], user)
      assert result.status == :connected
      refute result.already_imported

      server = result.server
      assert server.source == :registry
      assert server.registry_name == "io.github.acme/widget"
      assert server.registry_version == "1.2.3"
      assert server.description == "A widget server"
      assert server.handle == "widget"

      {:ok, reloaded} = MCP.get_server(server.id, actor: user)
      assert reloaded.reachability == :ok
      assert [%{"name" => "echo"}] = reloaded.cached_tools
    end

    test "is idempotent for the same registry name in the same scope", %{
      user: user,
      bypass: bypass
    } do
      assert {:ok, first} = Importer.import_entry(entry(bypass), [], user)
      assert {:ok, second} = Importer.import_entry(entry(bypass), [], user)

      assert second.already_imported
      assert second.server.id == first.server.id
    end

    test "leaves an auth-requiring server at needs_auth without discovery", %{
      user: user,
      bypass: bypass
    } do
      headers = [
        %{
          name: "Authorization",
          template: "Bearer {key}",
          vars: ["key"],
          secret: true,
          required: true,
          description: nil
        }
      ]

      assert {:ok, result} =
               Importer.import_entry(
                 entry(bypass, auth_type: :static_header, required_headers: headers),
                 [],
                 user
               )

      assert result.status == :needs_auth
      assert [%{name: "Authorization"}] = result.required_headers
      assert result.server.auth_type == :static_header
      # No discovery ran: tools stay empty until credentials are supplied.
      assert result.server.cached_tools == []
    end

    test "rejects a registry entry whose remote points at a private/internal host (SSRF)",
         %{user: user} do
      # Prod never sets `allow_private_urls`; flip it off so `SafeUrl` runs the
      # real SSRF check (config/test.exs enables it for Bypass on 127.0.0.1).
      previous = Application.get_env(:magus, Magus.MCP, [])
      Application.put_env(:magus, Magus.MCP, Keyword.put(previous, :allow_private_urls, false))
      on_exit(fn -> Application.put_env(:magus, Magus.MCP, previous) end)

      # A malicious registry entry aiming at the cloud-metadata endpoint must not
      # bypass SSRF protection: `MCP.create_server`'s SafeUrl validation rejects it.
      malicious = %RegistryEntry{
        registry_name: "io.github.evil/ssrf",
        display_name: "SSRF Probe",
        description: "Points at the cloud metadata endpoint",
        version: "1.0.0",
        repository_url: nil,
        transport: :streamable_http,
        endpoint_url: "http://169.254.169.254/mcp",
        auth_type: :none,
        required_headers: []
      }

      assert {:error, error} = Importer.import_entry(malicious, [], user)
      assert %Ash.Error.Invalid{} = error

      # No server row was created for the malicious entry.
      {:ok, servers} = MCP.list_accessible_servers(actor: user)
      refute Enum.any?(servers, &(&1.registry_name == "io.github.evil/ssrf"))
    end
  end
end
