defmodule Magus.Agents.ToolsTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Tools.{DiceRoll, CreateNote}
  alias Magus.Agents.Tools.Web.WebSearch

  describe "DiceRoll" do
    test "rolls dice with valid notation" do
      assert {:ok, result} = DiceRoll.run(%{dice: "2d6"}, %{})
      assert result.dice == "2d6"
      assert is_list(result.rolls)
      assert length(result.rolls) == 2
      assert Enum.all?(result.rolls, &(&1 >= 1 and &1 <= 6))
      assert result.total == Enum.sum(result.rolls)
      assert is_binary(result.formatted)
    end

    test "rolls single die" do
      assert {:ok, result} = DiceRoll.run(%{dice: "1d20"}, %{})
      assert result.dice == "1d20"
      assert length(result.rolls) == 1
      assert hd(result.rolls) >= 1 and hd(result.rolls) <= 20
    end

    test "handles invalid notation" do
      assert {:ok, result} = DiceRoll.run(%{dice: "invalid"}, %{})
      assert result.error
      assert result.hint
    end

    test "provides display_name" do
      assert DiceRoll.display_name() == "Rolling dice..."
    end
  end

  describe "CreateNote" do
    test "provides display_name" do
      assert CreateNote.display_name() == "Creating note..."
    end
  end

  describe "WebSearch" do
    test "provides display_name" do
      assert WebSearch.display_name() == "Searching the web..."
    end

    test "provides system_prompt_context" do
      context = WebSearch.system_prompt_context()
      assert is_binary(context)
      assert context =~ "web_search"
    end
  end
end
