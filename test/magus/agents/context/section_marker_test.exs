defmodule Magus.Agents.Context.SectionMarkerTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Context.SectionMarker

  describe "wrap/2" do
    test "prefixes a marker line onto a non-empty body" do
      assert SectionMarker.wrap(:tasks, "## Tasks\n- a") == "<!--ctx:tasks-->\n## Tasks\n- a"
    end

    test "passes nil and empty bodies through untouched (so callers still drop them)" do
      assert SectionMarker.wrap(:tasks, nil) == nil
      assert SectionMarker.wrap(:tasks, "") == ""
    end
  end

  describe "category/1" do
    test "round-trips the category out of a wrapped section's first line" do
      first_line =
        :workspace
        |> SectionMarker.wrap("## Active Workspace\nbody")
        |> String.split("\n")
        |> hd()

      assert SectionMarker.category(first_line) == :workspace
    end

    test "returns nil for an unmarked line" do
      assert SectionMarker.category("## Tasks") == nil
      assert SectionMarker.category("You are Magus") == nil
    end

    test "returns nil for an unknown marker key rather than minting an atom" do
      assert SectionMarker.category("<!--ctx:definitely_not_a_real_category-->") == nil
    end

    test "is nil-safe" do
      assert SectionMarker.category(nil) == nil
    end
  end
end
