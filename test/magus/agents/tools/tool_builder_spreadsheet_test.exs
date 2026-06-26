defmodule Magus.Agents.Tools.ToolBuilderSpreadsheetTest do
  @moduledoc """
  Verifies that the spreadsheet tools (`read_sheet`, `write_cells`) are
  registered in `Magus.Agents.Tools.ToolBuilder.build_tools/4` for chat
  conversations and exposed via the skill mapping. Both tools should be
  available to the main conversation agent so it can inspect and update
  `.xlsx` workbooks alongside the user.
  """

  use Magus.ResourceCase, async: false

  import Magus.Generators

  alias Magus.Agents.Tools.Spreadsheet.{ReadSheet, WriteCells}
  alias Magus.Agents.Tools.ToolBuilder

  test "ReadSheet and WriteCells are registered in main_tools for chat" do
    user = generate(user())
    agent = custom_agent(user)

    conv =
      generate(conversation(actor: user, custom_agent_id: agent.id))
      |> Ash.load!([:user, :custom_agent], actor: user)

    {tools, _ctx} = ToolBuilder.build_tools(:chat, conv, true, nil)

    assert ReadSheet in tools
    assert WriteCells in tools
  end

  test "skill_tool_mapping exposes the spreadsheet tools" do
    mapping = ToolBuilder.skill_tool_mapping()

    assert Map.get(mapping, "read_sheet") == ReadSheet
    assert Map.get(mapping, "write_cells") == WriteCells
  end

  test "tool_to_category classifies spreadsheet tools as :files" do
    categories = ToolBuilder.tool_to_category()

    assert Map.get(categories, ReadSheet) == :files
    assert Map.get(categories, WriteCells) == :files
  end
end
