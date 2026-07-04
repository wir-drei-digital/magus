defmodule Magus.SuperBrain.RetrievalTest do
  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  import Mox

  alias Magus.SuperBrain.Retrieval

  setup do
    user = generate(user())
    brain_a = generate(brain(user_id: user.id))
    brain_b = generate(brain(user_id: user.id))
    ga = "brain:#{brain_a.id}"
    gb = "brain:#{brain_b.id}"

    on_exit(fn ->
      Magus.Graph.drop(ga)
      Magus.Graph.drop(gb)
    end)

    # Seed entities with embeddings before creating the vector index so
    # the indexed property is present at index-build time.
    seed(ga, "Daniel", :person, [1.0, 0.0, 0.0, 0.0])
    seed(ga, "Project Aurora", :project, [0.9, 0.1, 0.0, 0.0])
    seed(gb, "Daniel", :person, [1.0, 0.0, 0.0, 0.0])
    seed(gb, "Sandbox Tool", :technology, [0.0, 1.0, 0.0, 0.0])

    Magus.Graph.Vector.create_index(ga, "Entity", "embedding", dim: 4, similarity: :cosine)
    Magus.Graph.Vector.create_index(gb, "Entity", "embedding", dim: 4, similarity: :cosine)

    {:ok, user: user, ga: ga, gb: gb}
  end

  defp seed(graph, name, type, embedding) do
    Magus.Graph.upsert_node(graph, "Entity", %{
      id: name |> :erlang.phash2() |> Integer.to_string(),
      name: name,
      type: Atom.to_string(type),
      embedding: embedding,
      confidence: 0.8,
      trust_tier: "evidence"
    })
  end

  test "fans out across accessible graphs and merges results", %{user: user} do
    {:ok, results} =
      Retrieval.search(user,
        query: "Daniel",
        query_embedding: [1.0, 0.0, 0.0, 0.0]
      )

    names = Enum.map(results, & &1.entity.name)
    assert "Daniel" in names
    # Daniel appears in both brain_a and brain_b, so we expect at least
    # two candidates from the fan-out.
    assert length(results) >= 2
  end

  test "returns no results when actor has no accessible brain graphs" do
    isolated = generate(user())

    {:ok, results} =
      Retrieval.search(isolated,
        query: "Daniel",
        query_embedding: [1.0, 0.0, 0.0, 0.0]
      )

    # AccessibleGraphs always returns the personal memories/files/drafts
    # graphs, but those graphs do not exist in FalkorDB for an isolated
    # user, so knn_search returns an error and Retrieval skips them.
    assert results == []
  end

  test "1-hop neighborhood boosts candidates with strong context", %{user: user, ga: ga} do
    # Add a related entity with an edge to Daniel
    Magus.Graph.upsert_node(ga, "Entity", %{
      id: "rel-1",
      name: "Distributed Consensus",
      type: "concept",
      embedding: [1.0, 0.0, 0.0, 0.0],
      confidence: 0.7,
      trust_tier: "evidence"
    })

    Magus.Graph.upsert_edge(
      ga,
      %{
        from_label: "Entity",
        from_id: "Daniel" |> :erlang.phash2() |> Integer.to_string(),
        to_label: "Entity",
        to_id: "rel-1"
      },
      "RELATES_TO",
      %{predicate: "researches", confidence: 0.8, trust_tier: "evidence"}
    )

    {:ok, results} =
      Retrieval.search(user,
        query: "distributed consensus",
        query_embedding: [1.0, 0.0, 0.0, 0.0]
      )

    # Daniel should rank higher than usual because his neighborhood
    # contains a hit with high cosine similarity to the query.
    daniel = Enum.find(results, fn r -> r.entity.name == "Daniel" end)
    assert daniel.neighborhood_support > 1.0
  end

  test "ranks closer vectors above orthogonal vectors", %{user: user, ga: ga} do
    # The setup seeded Daniel ([1,0,0,0]) and Project Aurora ([0.9,0.1,0,0])
    # in ga. Add an orthogonal entity that must rank LAST under the
    # corrected distance->similarity inversion. (FalkorDB returns cosine
    # DISTANCE, where 0 = identical and 1 = orthogonal; pre-fix this was
    # being read as similarity and orthogonal vectors ranked first.)
    Magus.Graph.upsert_node(ga, "Entity", %{
      id: "ortho-1",
      name: "Unrelated",
      type: "concept",
      embedding: [0.0, 0.0, 1.0, 0.0],
      confidence: 0.8,
      trust_tier: "evidence"
    })

    {:ok, results} =
      Retrieval.search(user,
        query: "Daniel",
        query_embedding: [1.0, 0.0, 0.0, 0.0]
      )

    names = Enum.map(results, & &1.entity.name)
    daniel_idx = Enum.find_index(names, &(&1 == "Daniel"))
    unrelated_idx = Enum.find_index(names, &(&1 == "Unrelated"))

    assert daniel_idx != nil and unrelated_idx != nil

    assert daniel_idx < unrelated_idx,
           "Daniel (identical) should rank above Unrelated (orthogonal). Got order: #{inspect(names)}"
  end

  describe "aggregate_per_graph/1" do
    test "every error == :graph_unavailable yields :all_graphs_unavailable" do
      per_graph = [
        {"brain:a", {:error, :graph_unavailable}},
        {"brain:b", {:error, :graph_unavailable}},
        {"brain:c", {:error, :graph_unavailable}}
      ]

      assert Magus.SuperBrain.Retrieval.aggregate_per_graph(per_graph) ==
               {:error, :all_graphs_unavailable}
    end

    test "any success yields {:ok, lists}" do
      per_graph = [
        {"brain:a", {:error, :graph_unavailable}},
        {"brain:b", {:ok, []}},
        {"brain:c", {:error, :graph_unavailable}}
      ]

      assert {:ok, lists} = Magus.SuperBrain.Retrieval.aggregate_per_graph(per_graph)
      assert lists == [[]]
    end

    test "all errored but none :graph_unavailable yields {:ok, []}" do
      per_graph = [
        {"brain:a", {:error, :timeout}},
        {"brain:b", {:error, :unknown}}
      ]

      assert Magus.SuperBrain.Retrieval.aggregate_per_graph(per_graph) == {:ok, []}
    end
  end

  describe "super-graph-first retrieval (iter3)" do
    setup :set_mox_from_context
    setup :verify_on_exit!

    test "cold start falls back to fan-out and enqueues initial build" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      page = generate(brain_page(brain_id: brain.id, user_id: user.id, content: "x"))
      graph = "brain:#{brain.id}"
      super_graph = "super:user:#{user.id}"

      on_exit(fn ->
        Magus.Graph.drop(graph)
        Magus.Graph.drop(super_graph)
      end)

      Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_many, fn texts ->
        {:ok, Enum.map(texts, fn _ -> List.duplicate(1.0, 1536) end)}
      end)

      Mox.stub(Magus.Embeddings.BatchEmbedderMock, :embed_one, fn _text ->
        {:ok, List.duplicate(1.0, 1536)}
      end)

      expect(Magus.SuperBrain.LLMMock, :complete, fn _, _ ->
        {:ok,
         %{
           content:
             ~s({"entities":[{"name":"X","type":"concept","subtype":null,"confidence":0.8}],"claims":[]}),
           usage: %Magus.SuperBrain.Usage{
             model_name: "t",
             total_tokens: 1,
             input_cost: Decimal.new("0"),
             output_cost: Decimal.new("0"),
             total_cost: Decimal.new("0")
           }
         }}
      end)

      :ok = perform_job(Magus.SuperBrain.Workers.ExtractBrainPage, %{"resource_id" => page.id})

      # Drain the iter3 fan-out (BuildSuperIncremental) so it doesn't interfere
      # with this test.
      Oban.drain_queue(queue: :super_brain_extraction, with_safety: false)

      # Clear any pending jobs and any SuperGraph row that may have been created
      # by the drained workers so we exercise the true cold-start path.
      {:ok, _} = Oban.delete_all_jobs(Oban.Job)

      Magus.SuperBrain.SuperGraph
      |> Ash.read!(authorize?: false)
      |> Enum.each(&Ash.destroy!(&1, authorize?: false))

      {:ok, _result} =
        Magus.SuperBrain.Retrieval.search(user,
          query: "X",
          query_embedding: List.duplicate(1.0, 1536),
          workspace_context: nil
        )

      assert_enqueued(
        worker: Magus.SuperBrain.Workers.BuildSuperFull,
        args: %{"user_id" => user.id, "accessor_type" => "user"}
      )
    end
  end
end
