defmodule Magus.SuperBrain.FalkorValuesTest do
  @moduledoc """
  Decoders for FalkorDB Cypher values. The verbose protocol returns
  numeric scalars as strings and `vecf32([...])` properties as the
  string literal `"<f1, f2, ...>"`, so callers MUST be able to recover
  the original shapes.
  """

  use ExUnit.Case, async: true

  alias Magus.SuperBrain.FalkorValues

  describe "parse_number/2" do
    test "passes numbers through as floats" do
      assert FalkorValues.parse_number(1, 0.0) == 1.0
      assert FalkorValues.parse_number(3.14, 0.0) == 3.14
    end

    test "parses numeric binaries" do
      assert FalkorValues.parse_number("0.42", 0.0) == 0.42
      assert FalkorValues.parse_number("7", 0.0) == 7.0
    end

    test "returns default for nil" do
      assert FalkorValues.parse_number(nil, 9.0) == 9.0
    end

    test "returns default for non-numeric binaries" do
      assert FalkorValues.parse_number("nope", 1.0) == 1.0
    end

    test "returns default for unexpected shapes" do
      assert FalkorValues.parse_number([1, 2], 2.5) == 2.5
      assert FalkorValues.parse_number(%{}, 2.5) == 2.5
    end
  end

  describe "parse_embedding/1" do
    test "returns [] for nil and empty list" do
      assert FalkorValues.parse_embedding(nil) == []
      assert FalkorValues.parse_embedding([]) == []
    end

    test "passes lists through" do
      assert FalkorValues.parse_embedding([1.0, 2.0]) == [1.0, 2.0]
    end

    test "parses FalkorDB string-encoded vecf32" do
      assert FalkorValues.parse_embedding("<1.000000, 0.500000, 0.250000>") == [1.0, 0.5, 0.25]
    end

    test "tolerates whitespace + missing brackets" do
      assert FalkorValues.parse_embedding(" 1.0,  2.0 ,3.0") == [1.0, 2.0, 3.0]
    end

    test "drops empty tokens" do
      assert FalkorValues.parse_embedding("<1.0,,2.0>") == [1.0, 2.0]
    end

    test "returns [] for unexpected shapes" do
      assert FalkorValues.parse_embedding(123) == []
      assert FalkorValues.parse_embedding(%{}) == []
    end
  end

  describe "cosine_similarity/2" do
    test "returns 0.0 when either side is empty" do
      assert FalkorValues.cosine_similarity([], [1.0]) == 0.0
      assert FalkorValues.cosine_similarity([1.0], []) == 0.0
    end

    test "computes the right value for unit vectors" do
      assert FalkorValues.cosine_similarity([1.0, 0.0], [1.0, 0.0]) == 1.0
      assert FalkorValues.cosine_similarity([1.0, 0.0], [0.0, 1.0]) == 0.0
    end

    test "returns 0.0 for length mismatches and zero norms" do
      assert FalkorValues.cosine_similarity([1.0], [1.0, 0.0]) == 0.0
      assert FalkorValues.cosine_similarity([0.0, 0.0], [1.0, 0.0]) == 0.0
    end
  end

  describe "most_common/1" do
    test "returns the modal element" do
      assert FalkorValues.most_common(["a", "b", "a"]) == "a"
    end

    test "filters out nils" do
      assert FalkorValues.most_common([nil, "x", nil, "x", "y"]) == "x"
    end

    test "returns relates_to as the empty-list fallback" do
      assert FalkorValues.most_common([]) == "relates_to"
      assert FalkorValues.most_common([nil, nil]) == "relates_to"
    end
  end
end
