defmodule Magus.Agents.Tools.Search.LoadToolMcpTest do
  # NOTE: The brief specified `Magus.DataCase` + `Magus.AccountsFixtures` /
  # `Magus.ChatFixtures`, but none of those exist in this codebase. This suite
  # uses `Magus.ResourceCase` + `generate(user())` + `Chat.create_conversation`
  # (the real helpers), matching the prior MCP task (test/magus/agents/tools/
  # catalog_mcp_test.exs) and the existing load_tool_test.exs. Behavior asserted
  # is identical to the brief.
  use Magus.ResourceCase, async: false

  import Magus.Generators

  alias Magus.Agents.Tools.Search.LoadTool
  alias Magus.Chat

  setup do
    user = generate(user())
    {:ok, conv} = Chat.create_conversation(%{}, actor: user)

    {:ok, server} =
      Magus.MCP.create_server(
        %{name: "Svc", handle: "svc", url: "https://example.test", auth_type: :none},
        actor: user
      )

    {:ok, _server} =
      Magus.MCP.update_server_cached_tools(
        server,
        %{
          cached_tools: [
            %{
              "name" => "do_thing",
              "description" => "Does a thing",
              "input_schema" => %{"type" => "object", "properties" => %{}},
              "annotations" => %{}
            }
          ]
        },
        actor: user
      )

    {:ok, user: user, conv: conv}
  end

  test "loads an MCP tool: persists coined name and returns __new_mcp_tools__", %{
    user: user,
    conv: conv
  } do
    context = %{user: user, user_id: user.id, conversation_id: conv.id}
    assert {:ok, result} = LoadTool.run(%{names: ["svc__do_thing"]}, context)
    assert "svc__do_thing" in result.loaded
    assert [%{coined_name: "svc__do_thing"} | _] = result.__new_mcp_tools__

    {:ok, reloaded} = Chat.get_conversation(conv.id, authorize?: false)
    assert "svc__do_thing" in reloaded.loaded_tools
  end

  test "an inaccessible MCP name is reported unknown, not loaded", %{conv: conv} do
    other = generate(user())
    context = %{user: other, user_id: other.id, conversation_id: conv.id}
    assert {:ok, result} = LoadTool.run(%{names: ["svc__do_thing"]}, context)
    assert "svc__do_thing" in result.unknown
    refute "svc__do_thing" in result.loaded
    refute Map.has_key?(result, :__new_mcp_tools__)

    {:ok, reloaded} = Chat.get_conversation(conv.id, authorize?: false)
    refute "svc__do_thing" in (reloaded.loaded_tools || [])
  end

  test "loads an internal tool with no user in context (static-only degradation)", %{conv: conv} do
    # No real %User{} and no user_id -> actor is nil -> Catalog returns static-only.
    # Internal modules still resolve; MCP names fall through to unknown.
    context = %{conversation_id: conv.id}
    assert {:ok, result} = LoadTool.run(%{names: ["roll_dice", "svc__do_thing"]}, context)
    assert "roll_dice" in result.loaded
    assert "svc__do_thing" in result.unknown
    assert Magus.Agents.Tools.DiceRoll in result.__new_tools__
    refute Map.has_key?(result, :__new_mcp_tools__)
  end
end
