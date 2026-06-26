defmodule Magus.Graph.QueryTest do
  use ExUnit.Case, async: true
  alias Magus.Graph.Query

  describe "bind_params/2" do
    test "interpolates string params with escaping" do
      sql = Query.bind_params("MATCH (n) WHERE n.name = $name RETURN n", %{name: "O'Brien"})
      assert sql == "MATCH (n) WHERE n.name = 'O\\'Brien' RETURN n"
    end

    test "interpolates integer params" do
      sql = Query.bind_params("RETURN $n", %{n: 42})
      assert sql == "RETURN 42"
    end

    test "interpolates list params as Cypher arrays" do
      sql = Query.bind_params("RETURN $xs", %{xs: [1, 2, 3]})
      assert sql == "RETURN [1, 2, 3]"
    end

    test "raises on missing param" do
      assert_raise KeyError, fn ->
        Query.bind_params("RETURN $missing", %{})
      end
    end
  end

  describe "decode_result/1" do
    test "decodes a typical GRAPH.QUERY response" do
      raw = [
        ["n.name", "n.age"],
        [["Daniel", 30], ["Alice", 25]],
        ["Cached execution: 1", "Query internal execution time: 0.123 ms"]
      ]

      {:ok, %{columns: cols, rows: rows}} = Query.decode_result(raw)

      assert cols == ["n.name", "n.age"]
      assert rows == [["Daniel", 30], ["Alice", 25]]
    end
  end
end
