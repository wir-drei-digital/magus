defmodule Magus.Agents.Tools.Search.ToolSearchTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Tools.Search.ToolSearch

  test "returns matches for a query" do
    {:ok, result} = ToolSearch.run(%{query: "roll a dice"}, %{})
    names = Enum.map(result.matches, & &1.name)
    assert "roll_dice" in names

    [first | _] = result.matches
    assert Map.has_key?(first, :name)
    assert Map.has_key?(first, :description)
    assert Map.has_key?(first, :category)
  end

  test "respects the limit param" do
    {:ok, result} = ToolSearch.run(%{query: "create list image video model", limit: 2}, %{})
    assert length(result.matches) <= 2
  end

  test "falls back to the loadable-tools menu when nothing matches" do
    {:ok, result} = ToolSearch.run(%{query: "photosynthesis chlorophyll metabolism"}, %{})
    # No keyword match, so the tool surfaces the available tools instead of an
    # empty result, with a note explaining the fallback.
    refute result.matches == []
    assert "roll_dice" in Enum.map(result.matches, & &1.name)
    assert Map.has_key?(result, :note)
  end

  test "a blank query returns the available-tools menu" do
    {:ok, result} = ToolSearch.run(%{query: ""}, %{})
    assert "roll_dice" in Enum.map(result.matches, & &1.name)
    assert Map.has_key?(result, :note)
  end

  test "exposes the expected metadata" do
    assert ToolSearch.name() == "tool_search"
    assert is_binary(ToolSearch.description())
  end
end
