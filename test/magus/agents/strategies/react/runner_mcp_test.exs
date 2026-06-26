defmodule Magus.Agents.Strategies.React.RunnerMcpTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Strategies.ReactStrategy.Runner

  test "append_mcp_tools/2 appends carrier structs to the :tools opt" do
    tool =
      ReqLLM.Tool.new!(
        name: "svc__t",
        description: "d",
        parameter_schema: %{"type" => "object", "properties" => %{}},
        callback: fn _ -> {:ok, %{}} end
      )

    context = %{
      __mcp_tools__: [%{coined_name: "svc__t", tool: tool, server_id: "s", remote_name: "t"}]
    }

    opts = [tools: [], temperature: 0.2]

    appended = Runner.append_mcp_tools(opts, context)
    assert Enum.any?(Keyword.fetch!(appended, :tools), &(&1.name == "svc__t"))
  end

  test "append_mcp_tools/2 is a no-op without a carrier" do
    opts = [tools: [], temperature: 0.2]
    assert Runner.append_mcp_tools(opts, %{}) == opts
  end

  test "mcp_tool_entry/2 finds a carrier entry by coined name" do
    context = %{
      __mcp_tools__: [%{coined_name: "svc__t", tool: nil, server_id: "s", remote_name: "t"}]
    }

    assert %{remote_name: "t", server_id: "s"} = Runner.mcp_tool_entry(context, "svc__t")
    assert Runner.mcp_tool_entry(context, "nope") == nil
  end
end
