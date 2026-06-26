defmodule Magus.SuperBrain.SourceRefsTest do
  use ExUnit.Case, async: true

  alias Magus.SuperBrain.SourceRefs

  describe "from_pair_strings/1" do
    test "parses, dedups, and sorts deterministically" do
      refs =
        SourceRefs.from_pair_strings([
          "draft|d2",
          "brain_page|p1",
          "brain_page|p1",
          "brain_page|p0"
        ])

      assert refs == [
               %{"resource_type" => "brain_page", "resource_id" => "p0"},
               %{"resource_type" => "brain_page", "resource_id" => "p1"},
               %{"resource_type" => "draft", "resource_id" => "d2"}
             ]
    end

    test "drops nils and malformed entries (e.g. from OPTIONAL MATCH on entities with no episode)" do
      assert SourceRefs.from_pair_strings([nil, "", "noseparator", "brain_page|p1"]) ==
               [%{"resource_type" => "brain_page", "resource_id" => "p1"}]
    end

    test "non-list input yields []" do
      assert SourceRefs.from_pair_strings(nil) == []
    end
  end

  describe "encode/1 and decode/1 round-trip" do
    test "decode returns atom-keyed maps" do
      refs = SourceRefs.from_pair_strings(["brain_page|p1", "draft|d2"])
      json = SourceRefs.encode(refs)

      assert SourceRefs.decode(json) == [
               %{resource_type: "brain_page", resource_id: "p1"},
               %{resource_type: "draft", resource_id: "d2"}
             ]
    end

    test "decode tolerates nil/blank/garbage" do
      assert SourceRefs.decode(nil) == []
      assert SourceRefs.decode("") == []
      assert SourceRefs.decode("not json") == []
      assert SourceRefs.decode("[1,2,3]") == []
    end
  end
end
