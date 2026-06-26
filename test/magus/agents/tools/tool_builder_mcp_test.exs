defmodule Magus.Agents.Tools.ToolBuilderMcpTest do
  # NOTE: The brief sketched `Magus.DataCase` + `Magus.AccountsFixtures.user_fixture()`,
  # but neither exists here. This suite uses `Magus.ResourceCase` + `generate(user())`
  # (the real helpers), matching catalog_mcp_test.exs / tool_builder_loaded_tools_test.exs.
  use Magus.ResourceCase, async: false

  import Magus.Generators

  alias Magus.Agents.Tools.ToolBuilder
  alias Magus.Chat

  # `build_tools/6` returns `{tools, tool_contexts}`. The MCP carrier is seeded into
  # the base tool_context, so it appears (identically) on every per-tool context.
  # `shared_tool_context/1` (in Preflight) is the intersection of those, so the
  # carrier survives into `base_tool_context` -> `effective_tool_context` ->
  # `context[:__mcp_tools__]`. We assert the observable builder output here.
  defp mcp_carrier(tool_contexts) do
    tool_contexts
    |> Map.values()
    |> Enum.filter(&is_map/1)
    |> Enum.find_value([], fn ctx -> Map.get(ctx, :__mcp_tools__) end)
  end

  defp build_conversation(user, attrs) do
    {:ok, conversation} = Chat.create_conversation(attrs, actor: user)
    Ash.load!(conversation, [:user], authorize?: false)
  end

  defp accessible_server(user) do
    {:ok, server} =
      Magus.MCP.create_server(
        %{name: "Svc", handle: "svc", url: "https://example.test", auth_type: :none},
        actor: user
      )

    {:ok, server} =
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

    server
  end

  test "tier-5 re-resolve carries MCP carrier entries for the owner" do
    user = generate(user())
    _server = accessible_server(user)
    conversation = build_conversation(user, %{loaded_tools: ["svc__do_thing"]})

    {_tools, tool_contexts} = ToolBuilder.build_tools(:chat, conversation, true, nil)

    carrier = mcp_carrier(tool_contexts)

    assert Enum.any?(carrier, &(&1.coined_name == "svc__do_thing")),
           "expected __mcp_tools__ to carry the loaded MCP tool, got: #{inspect(carrier)}"

    entry = Enum.find(carrier, &(&1.coined_name == "svc__do_thing"))
    assert entry.remote_name == "do_thing"
    assert %ReqLLM.Tool{} = entry.tool
  end

  test "no MCP loaded_tools yields an empty carrier" do
    user = generate(user())
    _server = accessible_server(user)
    conversation = build_conversation(user, %{loaded_tools: []})

    {_tools, tool_contexts} = ToolBuilder.build_tools(:chat, conversation, true, nil)

    assert mcp_carrier(tool_contexts) == []
  end

  test "a server the actor cannot access drops out of the carrier" do
    owner = generate(user())
    _server = accessible_server(owner)

    # A different user owns the conversation and never gained access to owner's server.
    stranger = generate(user())
    conversation = build_conversation(stranger, %{loaded_tools: ["svc__do_thing"]})

    {_tools, tool_contexts} = ToolBuilder.build_tools(:chat, conversation, true, nil)

    assert mcp_carrier(tool_contexts) == []
  end
end
