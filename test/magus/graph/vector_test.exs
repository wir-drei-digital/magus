defmodule Magus.Graph.VectorTest do
  use ExUnit.Case, async: false
  alias Magus.Graph.Vector

  setup do
    graph = "test_vec_#{System.unique_integer([:positive])}"
    on_exit(fn -> Magus.Graph.drop(graph) end)
    {:ok, graph: graph}
  end

  test "creates a vector index and finds nearest neighbors", %{graph: graph} do
    :ok = Vector.create_index(graph, "Entity", "embedding", dim: 4, similarity: :cosine)

    for {id, vec} <- [
          {"e1", [1.0, 0.0, 0.0, 0.0]},
          {"e2", [0.9, 0.1, 0.0, 0.0]},
          {"e3", [0.0, 0.0, 1.0, 0.0]}
        ] do
      {:ok, _} = Magus.Graph.upsert_node(graph, "Entity", %{id: id, embedding: vec, name: id})
    end

    {:ok, hits} =
      Vector.knn_search(graph, "Entity", "embedding", [1.0, 0.0, 0.0, 0.0], k: 2)

    ids = Enum.map(hits, & &1.id)
    assert "e1" in ids
    assert "e2" in ids
    refute "e3" in ids
  end

  describe "ensure_index/4" do
    test "creates the index on first call" do
      graph = "test_ensure_index_#{System.unique_integer([:positive])}"
      on_exit(fn -> Magus.Graph.drop(graph) end)

      assert {:ok, :created} =
               Vector.ensure_index(graph, "Entity", "embedding",
                 dim: 3,
                 similarity: :cosine
               )
    end

    test "is idempotent across multiple calls" do
      graph = "test_ensure_index_#{System.unique_integer([:positive])}"
      on_exit(fn -> Magus.Graph.drop(graph) end)

      assert {:ok, :created} =
               Vector.ensure_index(graph, "Entity", "embedding",
                 dim: 3,
                 similarity: :cosine
               )

      assert {:ok, :already_exists} =
               Vector.ensure_index(graph, "Entity", "embedding",
                 dim: 3,
                 similarity: :cosine
               )
    end
  end
end
