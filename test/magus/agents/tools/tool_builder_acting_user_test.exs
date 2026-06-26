defmodule Magus.Agents.Tools.ToolBuilderActingUserTest do
  # Phase 3 Task 2: the MCP actor_context resolves for the ACTING user (message
  # author), not the conversation owner. The owner fallback (acting_user_id ==
  # nil) preserves Phase 2 behavior.
  #
  # Return-shape note: `build_tools/6` returns `{tools, tool_contexts}` (NOT a
  # struct with `base_tool_context`). The MCP carrier is seeded into the base
  # tool_context, so it appears identically on every per-tool context; we read it
  # back the same way Preflight's `shared_tool_context/1` intersection would.
  # Mirrors `tool_builder_mcp_test.exs`.
  use Magus.ResourceCase, async: false

  import Magus.Generators

  alias Magus.Agents.Tools.ToolBuilder
  alias Magus.Chat

  defp mcp_carrier(tool_contexts) do
    tool_contexts
    |> Map.values()
    |> Enum.filter(&is_map/1)
    |> Enum.find_value([], fn ctx -> Map.get(ctx, :__mcp_tools__) end)
  end

  defp accessible_server(user) do
    {:ok, server} =
      Magus.MCP.create_server(
        %{name: "M", handle: "mem", url: "https://example.test", auth_type: :none},
        actor: user
      )

    {:ok, server} =
      Magus.MCP.update_server_cached_tools(
        server,
        %{
          cached_tools: [
            %{
              "name" => "do",
              "description" => "",
              "input_schema" => %{"type" => "object", "properties" => %{}},
              "annotations" => %{}
            }
          ]
        },
        actor: user
      )

    server
  end

  test "MCP tools resolve for the ACTING user, not the conversation owner" do
    owner = generate(user())
    member = generate(user())

    # member owns an MCP server with a cached tool; owner does NOT have access
    _server = accessible_server(member)

    # a conversation owned by `owner`, with the member's coined tool loaded
    {:ok, conv} =
      Chat.create_conversation(%{title: "c", loaded_tools: ["mem__do"]}, actor: owner)

    conv = Ash.load!(conv, [:user], authorize?: false)

    # Build tools as the OWNER (no acting user -> owner fallback) -> owner can't
    # access member's server -> no MCP carrier entry.
    {_tools, owner_contexts} =
      ToolBuilder.build_tools(:chat, conv, true, nil, nil, acting_user_id: nil)

    refute Enum.any?(mcp_carrier(owner_contexts), &(&1.coined_name == "mem__do")),
           "owner lacks access to member's server; carrier must not include mem__do"

    # Build tools with acting_user_id = member -> member's server resolves.
    {_tools, member_contexts} =
      ToolBuilder.build_tools(:chat, conv, true, nil, nil, acting_user_id: member.id)

    assert Enum.any?(mcp_carrier(member_contexts), &(&1.coined_name == "mem__do")),
           "acting user (member) can access their own server; carrier must include mem__do"
  end
end
