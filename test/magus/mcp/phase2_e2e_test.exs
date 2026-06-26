defmodule Magus.MCP.Phase2E2ETest do
  @moduledoc """
  End-to-end proof that the static-header/`:none` MCP flow works through the real
  pieces (no live LLM): discover + cache against the Bypass MockServer, surface the
  coined tool name via `tool_search`, enable it via `load_tool` (persisting it on
  the conversation), and finally dispatch the remote call through `Executor.call/4`.

  Also asserts the SSRF guard rejects a cloud-metadata target at `create_server`
  when the private-URL escape hatch is off.
  """
  use Magus.ResourceCase, async: false

  alias Magus.MCP
  alias Magus.MCP.{Executor, MockServer}
  alias Magus.Agents.Tools.Search.{ToolSearch, LoadTool}

  @moduletag :mcp_integration

  setup do
    bypass =
      MockServer.start(
        tools: [
          %{
            "name" => "echo",
            "description" => "Echo the supplied text back to the caller",
            "inputSchema" => %{
              "type" => "object",
              "properties" => %{"text" => %{"type" => "string"}}
            }
          }
        ]
      )

    user = generate(user())

    {:ok, server} =
      MCP.create_server(
        %{
          name: "Svc",
          handle: "svc",
          url: "http://127.0.0.1:#{bypass.port}",
          mcp_path: "/mcp",
          auth_type: :none
        },
        actor: user
      )

    # Warm the Finch pool against this fresh Bypass server. The test config uses a
    # tight `init_timeout_ms: 200`, and the first cold dial can exceed it; a
    # throwaway dial primes the pool so discovery below is deterministic. Mirrors
    # the pattern in executor_test.exs.
    warm_up(server)

    {:ok, server} = MCP.Discovery.discover_and_cache(server, user)

    conv = generate(conversation(actor: user))

    %{user: user, server: server, conv: conv, bypass: bypass}
  end

  defp warm_up(server, attempts \\ 3) do
    case MCP.ClientManager.with_client(server, %{}, fn client -> MCP.Client.list_tools(client) end) do
      {:ok, _} -> :ok
      _ when attempts > 1 -> warm_up(server, attempts - 1)
      _ -> :ok
    end
  end

  test "search finds the coined name, load enables it, executor calls the remote tool",
       %{user: user, server: server, conv: conv} do
    # The actor-scoped catalog drives search/load; `:user` MUST be a real %User{}.
    ctx = %{user: user, user_id: user.id, conversation_id: conv.id}

    # 1. Discovery cached the remote `echo` tool, so the catalog coins `svc__echo`.
    assert [%{"name" => "echo"}] = server.cached_tools

    # 2. tool_search surfaces the coined name for the actor.
    assert {:ok, %{matches: matches}} = ToolSearch.run(%{query: "echo"}, ctx)
    assert Enum.any?(matches, &(&1.name == "svc__echo"))

    # 3. load_tool returns the MCP carrier entry AND persists the coined name onto
    #    the conversation so it survives across turns / hibernation.
    assert {:ok, load_result} = LoadTool.run(%{names: ["svc__echo"]}, ctx)

    assert [carrier] = load_result.__new_mcp_tools__
    assert carrier.coined_name == "svc__echo"
    assert carrier.remote_name == "echo"
    assert carrier.server_id == server.id
    assert "svc__echo" in load_result.loaded

    {:ok, reloaded_conv} = Magus.Chat.get_conversation(conv.id, actor: user)
    assert "svc__echo" in (reloaded_conv.loaded_tools || [])

    # 4. The executor dispatches the remote call against the live (mock) server and
    #    returns the canned success payload with no :error key.
    {:ok, server} = MCP.get_server(carrier.server_id, actor: user)

    assert {:ok, result} = Executor.call(server, carrier.remote_name, %{"text" => "hello"}, ctx)
    assert is_map(result)
    refute Map.has_key?(result, :error)
    assert %{"content" => [%{"type" => "text", "text" => "ok"}]} = result
  end

  test "an internal/cloud-metadata URL is rejected by the SSRF guard at create", %{user: user} do
    # The happy-path tests above need `allow_private_urls: true` (the mock binds to
    # 127.0.0.1). Isolate a flag flip here so we genuinely exercise SafeUrl
    # rejection, preserving `init_timeout_ms` and restoring the original config.
    original = Application.get_env(:magus, Magus.MCP, [])

    on_exit(fn -> Application.put_env(:magus, Magus.MCP, original) end)

    Application.put_env(:magus, Magus.MCP,
      allow_private_urls: false,
      init_timeout_ms: Keyword.get(original, :init_timeout_ms, 200)
    )

    assert {:error, _} =
             MCP.create_server(
               %{
                 name: "Bad",
                 handle: "bad",
                 url: "http://169.254.169.254/latest/meta-data",
                 mcp_path: "/mcp",
                 auth_type: :none
               },
               actor: user
             )
  end
end
