defmodule MagusWeb.Rpc.McpRegistryControllerTest do
  @moduledoc """
  Exercises the MCP registry controller's static-header connect endpoint
  (`POST /rpc/mcp/servers/:id/connect`): storing per-user credentials, running
  discovery, and owner scoping. Registry browse/import are covered at the domain
  level (`Magus.MCP.ImporterTest`) since they hit the external registry.
  """
  use MagusWeb.ConnCase, async: false

  import Magus.Generators
  import MagusWeb.LiveViewCase, only: [log_in_user: 2]

  alias Magus.MCP

  @moduletag :mcp_integration

  setup do
    bypass =
      Magus.MCP.MockServer.start(
        tools: [%{"name" => "echo", "description" => "Echo", "inputSchema" => %{}}]
      )

    user = generate(user())

    {:ok, server} =
      MCP.create_server(
        %{
          name: "Mock",
          handle: "mock",
          url: "http://127.0.0.1:#{bypass.port}",
          auth_type: :static_header
        },
        actor: user
      )

    %{user: user, server: server}
  end

  test "connect stores static headers, discovers tools, and reports connected", %{
    conn: conn,
    user: user,
    server: server
  } do
    assert %{"success" => true, "data" => data} =
             conn
             |> log_in_user(user)
             |> put_req_header("content-type", "application/json")
             |> post("/rpc/mcp/servers/#{server.id}/connect", %{
               "headers" => %{"Authorization" => "Bearer secret-token"}
             })
             |> json_response(200)

    assert data["status"] == "connected"

    {:ok, credential} = MCP.get_credential_for_server(server.id, actor: user)
    assert credential.static_headers["Authorization"] == "Bearer secret-token"

    {:ok, reloaded} = MCP.get_server(server.id, actor: user)
    assert reloaded.reachability == :ok
    assert [%{"name" => "echo"}] = reloaded.cached_tools
  end

  test "a stranger cannot connect another user's server", %{conn: conn, server: server} do
    stranger = generate(user())

    assert %{"success" => false} =
             conn
             |> log_in_user(stranger)
             |> put_req_header("content-type", "application/json")
             |> post("/rpc/mcp/servers/#{server.id}/connect", %{
               "headers" => %{"Authorization" => "Bearer x"}
             })
             |> json_response(200)

    # No credential was created for the stranger.
    assert {:ok, nil} = MCP.get_credential_for_server(server.id, actor: stranger)
  end

  test "unauthenticated connect is rejected", %{conn: conn, server: server} do
    conn = post(conn, "/rpc/mcp/servers/#{server.id}/connect", %{"headers" => %{}})
    assert conn.status in [401, 302]
  end
end
