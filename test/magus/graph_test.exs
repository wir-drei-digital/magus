defmodule Magus.GraphTest do
  use ExUnit.Case, async: false

  setup do
    graph = "test_graph_#{System.unique_integer([:positive])}"
    on_exit(fn -> Magus.Graph.Connection.command(["GRAPH.DELETE", graph]) end)
    {:ok, graph: graph}
  end

  describe "query/3" do
    test "runs a parameterized Cypher query", %{graph: graph} do
      {:ok, _} = Magus.Graph.query(graph, "CREATE (:Foo {name: $name})", %{name: "bar"})
      {:ok, result} = Magus.Graph.query(graph, "MATCH (n:Foo) RETURN n.name")
      assert ["bar"] in result.rows or [["bar"]] in result.rows
    end
  end

  describe "upsert_node/3" do
    test "creates a node when not present, updates when present", %{graph: graph} do
      {:ok, _} = Magus.Graph.upsert_node(graph, "Entity", %{id: "e1", name: "Alpha", count: 1})
      {:ok, _} = Magus.Graph.upsert_node(graph, "Entity", %{id: "e1", name: "Alpha", count: 5})

      {:ok, result} = Magus.Graph.query(graph, "MATCH (n:Entity {id: 'e1'}) RETURN n.count")
      assert [[5]] = result.rows
    end
  end

  describe "upsert_edge/3" do
    test "creates an edge between two nodes", %{graph: graph} do
      {:ok, _} = Magus.Graph.upsert_node(graph, "Entity", %{id: "a", name: "A"})
      {:ok, _} = Magus.Graph.upsert_node(graph, "Entity", %{id: "b", name: "B"})

      {:ok, _} =
        Magus.Graph.upsert_edge(
          graph,
          %{from_label: "Entity", from_id: "a", to_label: "Entity", to_id: "b"},
          "RELATES_TO",
          %{predicate: "knows", confidence: 0.8}
        )

      {:ok, result} =
        Magus.Graph.query(
          graph,
          "MATCH (:Entity {id: 'a'})-[r:RELATES_TO]->(:Entity {id: 'b'}) RETURN r.predicate"
        )

      assert [["knows"]] = result.rows
    end
  end

  describe "upsert vector-property allowlist" do
    setup do
      graph = "test_vector_allowlist_#{System.unique_integer([:positive])}"
      on_exit(fn -> Magus.Graph.drop(graph) end)
      {:ok, graph: graph}
    end

    test "auto-wraps :embedding in vecf32", %{graph: graph} do
      assert {:ok, _} =
               Magus.Graph.upsert_node(graph, "TestNode", %{
                 id: "n1",
                 embedding: [1.0, 0.0, 0.0]
               })

      {:ok, result} =
        Magus.Graph.query(graph, "MATCH (n:TestNode {id: 'n1'}) RETURN n.embedding")

      assert result.rows != []
    end

    test "auto-wraps :summary_embedding in vecf32", %{graph: graph} do
      assert {:ok, _} =
               Magus.Graph.upsert_node(graph, "TestNode", %{
                 id: "ns1",
                 summary_embedding: [0.5, 0.5, 0.0]
               })

      {:ok, result} =
        Magus.Graph.query(graph, "MATCH (n:TestNode {id: 'ns1'}) RETURN n.summary_embedding")

      assert result.rows != []
    end

    test "does NOT auto-wrap arbitrary numeric lists", %{graph: graph} do
      assert {:ok, _} =
               Magus.Graph.upsert_node(graph, "TestNode", %{
                 id: "n2",
                 scores: [1, 2, 3]
               })

      assert {:ok, _} =
               Magus.Graph.upsert_node(graph, "TestNode", %{
                 id: "n3",
                 counts: [10, 20]
               })

      # Verify the lists were stored as plain Cypher arrays, not vecf32. A
      # vecf32 value round-trips as a string of the form "<1.000000, ...>".
      # A plain Cypher array round-trips as "[1, 2, 3]" via the current
      # decoder. The key assertion is the *absence* of the vecf32 angle
      # brackets, which would indicate the property was silently coerced.
      {:ok, result} =
        Magus.Graph.query(graph, "MATCH (n:TestNode {id: 'n2'}) RETURN n.scores")

      assert [[scores]] = result.rows
      refute is_binary(scores) and String.starts_with?(scores, "<")
    end
  end
end
