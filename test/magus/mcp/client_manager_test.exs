defmodule Magus.MCP.ClientManagerTest do
  use Magus.ResourceCase, async: false

  alias Magus.MCP
  alias Magus.MCP.ClientManager

  @moduletag :mcp_integration

  test "with_client connects and lists tools from a mock server" do
    bypass =
      Magus.MCP.MockServer.start(
        tools: [
          %{"name" => "echo", "description" => "Echo back", "inputSchema" => %{}},
          %{"name" => "search", "description" => "Search", "inputSchema" => %{}}
        ]
      )

    user = generate(user())

    {:ok, server} =
      MCP.create_server(
        %{name: "Mock", handle: "mock", url: "http://127.0.0.1:#{bypass.port}"},
        actor: user
      )

    # `with_client` returns the fun's value verbatim, and `Client.list_tools/1`
    # already yields `{:ok, tools}`, so the connect-and-list result is the
    # unwrapped tool list from the live anubis handshake against the mock.
    assert {:ok, [%{"name" => "echo"}, %{"name" => "search"}]} =
             ClientManager.with_client(server, fn client ->
               MCP.Client.list_tools(client)
             end)
  end

  test "with_client returns a typed error fast when the server is unreachable" do
    user = generate(user())
    # Port 1 is not listening.
    {:ok, server} =
      MCP.create_server(
        %{name: "Down", handle: "down", url: "http://127.0.0.1:1"},
        actor: user
      )

    {elapsed_us, result} =
      :timer.tc(fn -> ClientManager.with_client(server, fn _ -> :unreached end) end)

    # init_timeout_ms is 200 in test config, so this must resolve well under 1s
    # rather than the old hardcoded ~10s poll loop.
    assert elapsed_us < 1_000_000

    # The error surfaces as an {:error, reason} tuple rather than raising or
    # hanging. (start_client may fail at connect, or await_ready may time out;
    # both map to {:error, _} with an inspectable reason.)
    assert {:error, _reason} = result
  end

  test "with_client leaves no child process behind after a failed discovery" do
    user = generate(user())

    {:ok, server} =
      MCP.create_server(
        %{name: "Down", handle: "down", url: "http://127.0.0.1:1"},
        actor: user
      )

    assert {:error, _} = ClientManager.with_client(server, fn _ -> :unreached end)

    # Regression guard: a :transient one-shot client must be fully terminated
    # (and not auto-restarted under the same Registry name) by the time
    # with_client returns.
    assert %{active: 0, workers: 0} =
             Map.take(
               DynamicSupervisor.count_children(Magus.MCP.ClientDynamicSupervisor),
               [:active, :workers]
             )
  end

  test "with_client blocks a server whose URL is private when allow_private_urls is off" do
    user = generate(user())

    {:ok, server} =
      MCP.create_server(
        %{name: "Local", handle: "local", url: "http://127.0.0.1:1"},
        actor: user
      )

    prev = Application.get_env(:magus, Magus.MCP, [])
    Application.put_env(:magus, Magus.MCP, Keyword.put(prev, :allow_private_urls, false))
    on_exit(fn -> Application.put_env(:magus, Magus.MCP, prev) end)

    assert {:error, {:ssrf_blocked, _}} =
             ClientManager.with_client(server, fn _ -> :unreached end)

    # Never started a child.
    assert %{active: 0} =
             Map.take(
               DynamicSupervisor.count_children(Magus.MCP.ClientDynamicSupervisor),
               [:active]
             )
  end
end
