defmodule Magus.Agents.Tools.CatalogTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Tools.Catalog
  alias Magus.Agents.Tools.DiceRoll
  alias Magus.Agents.Tools.Media.GenerateImage

  describe "search/2" do
    test "finds the dice tool by keyword" do
      [top | _] = Catalog.search("roll some dice")
      assert top.name == "roll_dice"
    end

    test "finds the image tool by keyword" do
      results = Catalog.search("draw me a picture")
      assert "generate_image" in Enum.map(results, & &1.name)
    end

    test "returns no matches for an unrelated query" do
      assert Catalog.search("photosynthesis chlorophyll metabolism") == []
    end

    test "respects the limit option" do
      assert length(Catalog.search("create list image video model", limit: 2)) == 2
    end

    test "excludes already-loaded tools by name" do
      results = Catalog.search("roll some dice", exclude: ["roll_dice"])
      refute "roll_dice" in Enum.map(results, & &1.name)
    end
  end

  describe "resolve/1" do
    test "maps known names to modules" do
      assert {[DiceRoll], []} = Catalog.resolve(["roll_dice"])
    end

    test "reports unknown names" do
      assert {[], ["no_such_tool"]} = Catalog.resolve(["no_such_tool"])
    end

    test "every searchable tool resolves to a module (de-noise reachability)" do
      names = Enum.map(Catalog.entries(), & &1.name)
      {modules, unknown} = Catalog.resolve(names)
      assert unknown == []
      assert length(modules) == length(Enum.uniq(names))
    end
  end

  describe "hint_for/2" do
    test "produces a hint when the message matches a hidden tool" do
      hint = Catalog.hint_for("can you roll a dice", [])
      assert hint =~ "tool_search"
      assert hint =~ "roll_dice"
    end

    test "returns nil when nothing relevant is hidden" do
      assert Catalog.hint_for("photosynthesis chlorophyll metabolism", []) == nil
    end

    test "does not hint for a tool already loaded this turn" do
      assert Catalog.hint_for("roll a dice", [GenerateImage]) =~ "roll_dice"
      assert Catalog.hint_for("roll a dice", [DiceRoll]) == nil
    end
  end
end
