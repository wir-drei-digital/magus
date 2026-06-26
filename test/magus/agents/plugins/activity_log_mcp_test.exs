# test/magus/agents/plugins/activity_log_mcp_test.exs
defmodule Magus.Agents.Plugins.ActivityLogMcpTest do
  # async: false — the plugin logs synchronously in test (config
  # :activity_log_async false) and uses the per-process activity_log caches;
  # keep isolation via unique conversation/agent ids per test.
  use Magus.DataCase, async: false

  alias Magus.Agents.Plugins.ActivityLogPlugin

  import Magus.Generators

  # Build an MCP server owned by `user` with one cached tool, then a
  # conversation whose loaded_tools include that tool's coined name.
  defp setup_mcp(user, custom_agent_id) do
    {:ok, server} =
      Magus.MCP.create_server(
        %{name: "Weather Svc", handle: "weather", url: "https://example.test", auth_type: :none},
        actor: user
      )

    {:ok, server} =
      Magus.MCP.update_server_cached_tools(
        server,
        %{
          cached_tools: [
            %{
              "name" => "get_forecast",
              "description" => "Get the weather forecast",
              "input_schema" => %{"type" => "object", "properties" => %{}},
              "annotations" => %{}
            }
          ]
        },
        actor: user
      )

    coined = Magus.MCP.ToolAdapter.coin_tool_name(server.handle, "get_forecast")

    conv = generate(conversation(actor: user))

    {:ok, conv} =
      Magus.Chat.set_conversation_loaded_tools(conv, %{loaded_tools: [coined]}, actor: user)

    state = %{user_id: user.id, conversation_id: conv.id, custom_agent_id: custom_agent_id}

    %{agent: %{state: state}, server: server, coined: coined, conv: conv}
  end

  describe "handle_signal/2 - ai.tool.result for an MCP tool" do
    test "creates an :external_tool_call activity log referencing handle + remote tool" do
      user = generate(user())
      custom_agent = custom_agent(user)

      %{agent: agent, coined: coined} = setup_mcp(user, custom_agent.id)

      signal = %{
        type: "ai.tool.result",
        data: %{
          tool_name: coined,
          result: {:ok, %{"forecast" => "sunny"}}
        }
      }

      context = %{agent: agent}

      assert {:ok, :continue} = ActivityLogPlugin.handle_signal(signal, context)

      assert [log] = Magus.Agents.list_agent_activity!(custom_agent.id, authorize?: false)

      assert log.activity_type == :external_tool_call
      assert log.agent_id == custom_agent.id
      assert log.user_id == user.id
      assert log.summary =~ "weather"
      assert log.summary =~ "get_forecast"
      assert log.details["mcp_server_handle"] == "weather"
      assert log.details["tool"] == coined
      assert log.details["outcome"] == "ok"
    end

    test "marks outcome error when the MCP result is a soft error" do
      user = generate(user())
      custom_agent = custom_agent(user)

      %{agent: agent, coined: coined} = setup_mcp(user, custom_agent.id)

      signal = %{
        type: "ai.tool.result",
        data: %{
          tool_name: coined,
          result: {:ok, %{error: "MCP server weather timed out. Try again later."}}
        }
      }

      context = %{agent: agent}

      assert {:ok, :continue} = ActivityLogPlugin.handle_signal(signal, context)

      assert [log] = Magus.Agents.list_agent_activity!(custom_agent.id, authorize?: false)
      assert log.activity_type == :external_tool_call
      assert log.details["outcome"] == "error"
      assert log.summary =~ "error"
    end
  end

  describe "handle_signal/2 - ai.tool.result for a non-MCP tool" do
    test "does NOT create an :external_tool_call row for an internal tool" do
      user = generate(user())
      custom_agent = custom_agent(user)

      # Same setup, but the signal references an internal tool name, not the
      # coined MCP name.
      %{agent: agent} = setup_mcp(user, custom_agent.id)

      signal = %{
        type: "ai.tool.result",
        data: %{
          tool_name: "web_search",
          result: {:ok, %{"results" => []}}
        }
      }

      context = %{agent: agent}

      assert {:ok, :continue} = ActivityLogPlugin.handle_signal(signal, context)

      logs = Magus.Agents.list_agent_activity!(custom_agent.id, authorize?: false)
      refute Enum.any?(logs, &(&1.activity_type == :external_tool_call))
    end
  end
end
