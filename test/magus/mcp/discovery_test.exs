defmodule Magus.MCP.DiscoveryTest do
  use Magus.ResourceCase, async: false

  alias Magus.MCP
  alias Magus.MCP.Discovery

  @moduletag :mcp_integration

  setup do
    bypass =
      Magus.MCP.MockServer.start(
        tools: [%{"name" => "echo", "description" => "Echo", "inputSchema" => %{}}]
      )

    user = generate(user())

    {:ok, server} =
      MCP.create_server(
        %{name: "Mock", handle: "mock", url: "http://127.0.0.1:#{bypass.port}"},
        actor: user
      )

    %{user: user, server: server}
  end

  test "discover_and_cache stores normalized tools and marks reachable", %{
    user: user,
    server: server
  } do
    assert {:ok, updated} = Discovery.discover_and_cache(server, user)
    assert updated.reachability == :ok
    assert [%{"name" => "echo", "input_schema" => %{}}] = updated.cached_tools
    assert updated.tools_cached_at

    {:ok, reloaded} = MCP.get_server(server.id, actor: user)
    assert [%{"name" => "echo"}] = reloaded.cached_tools
    assert reloaded.last_reachable_at
  end

  test "discover_and_cache drops a malformed (nameless) tool instead of crashing", %{user: user} do
    bypass =
      Magus.MCP.MockServer.start(
        tools: [
          %{"name" => "good", "description" => "Good", "inputSchema" => %{}},
          %{"description" => "no name here"}
        ]
      )

    {:ok, server} =
      MCP.create_server(
        %{name: "Mixed", handle: "mixed", url: "http://127.0.0.1:#{bypass.port}"},
        actor: user
      )

    assert {:ok, updated} = Discovery.discover_and_cache(server, user)
    assert updated.reachability == :ok
    assert [%{"name" => "good"}] = updated.cached_tools
  end

  test "discover_and_cache records an error when unreachable and does not stamp last_reachable_at",
       %{user: user} do
    {:ok, down} =
      MCP.create_server(
        %{name: "Down", handle: "down", url: "http://127.0.0.1:1"},
        actor: user
      )

    assert {:error, _} = Discovery.discover_and_cache(down, user)

    {:ok, reloaded} = MCP.get_server(down.id, actor: user)
    assert reloaded.reachability == :error
    assert reloaded.last_reachable_at == nil
    # last_error stores a sanitized category, never a raw inspected reason.
    assert is_binary(reloaded.last_error)
    refute reloaded.last_error =~ "authorization"
    refute reloaded.last_error =~ "Bearer"
  end

  test "discover_and_cache returns a clean error (no MatchError) for a non-editor actor", %{
    server: server
  } do
    owner = generate(user())
    ws = generate(workspace(actor: owner))
    viewer = generate(user())
    workspace_member(user_id: viewer.id, workspace_id: ws.id, role: :member)

    {:ok, ws_server} =
      MCP.create_server(
        %{
          name: "Team",
          handle: "team",
          url: "http://127.0.0.1:#{server_port(server)}",
          workspace_id: ws.id
        },
        actor: owner
      )

    {:ok, _} =
      Magus.Workspaces.grant_access(
        %{
          resource_type: :mcp_server,
          resource_id: ws_server.id,
          grantee_type: :workspace,
          grantee_id: ws.id,
          role: :viewer
        },
        actor: owner
      )

    # A :viewer connects fine but cannot write cached_tools/reachability
    # (workspace_scoped_policies require :editor). Must return {:error, _},
    # not raise a MatchError.
    assert {:error, _} = Discovery.discover_and_cache(ws_server, viewer)
  end

  defp server_port(server) do
    %URI{port: port} = URI.parse(server.url)
    port
  end

  test "test_connection returns tools without persisting", %{user: user, server: server} do
    assert {:ok, [%{"name" => "echo"}]} = Discovery.test_connection(server, user)

    {:ok, reloaded} = MCP.get_server(server.id, actor: user)
    assert reloaded.cached_tools == []
  end
end
