defmodule Magus.SuperBrain.BuildSuperFullMetricsTest do
  use Magus.ResourceCase, async: false

  alias Magus.SuperBrain.SuperGraph
  alias Magus.SuperBrain.Workers.BuildSuperFull

  require Ash.Query

  test "build persists graph metrics on the SuperGraph row" do
    user = generate(user())
    brain = generate(brain(user_id: user.id))
    graph = "brain:#{brain.id}"
    super_graph = "super:user:#{user.id}"

    on_exit(fn ->
      Magus.Graph.drop(graph)
      Magus.Graph.drop(super_graph)
    end)

    # Seed two L1 entities with one RELATES_TO so metrics are non-trivial.
    Magus.Graph.upsert_node(graph, "Entity", %{
      id: "e1",
      name: "Daniel",
      type: "person",
      embedding: List.duplicate(0.0, 1536),
      confidence: 0.9,
      trust_tier: "evidence"
    })

    Magus.Graph.upsert_node(graph, "Entity", %{
      id: "e2",
      name: "Aurora",
      type: "project",
      embedding: List.duplicate(0.0, 1536),
      confidence: 0.9,
      trust_tier: "evidence"
    })

    Magus.Graph.upsert_edge(
      graph,
      %{from_label: "Entity", from_id: "e1", to_label: "Entity", to_id: "e2"},
      "RELATES_TO",
      %{predicate: "works_on", confidence: 0.8, trust_tier: "evidence"}
    )

    :ok =
      BuildSuperFull.perform(%Oban.Job{
        args: %{"accessor_type" => "user", "user_id" => user.id, "workspace_id" => nil}
      })

    row =
      SuperGraph
      |> Ash.Query.filter(graph_name == ^super_graph)
      |> Ash.read_one!(authorize?: false)

    assert is_map(row.metrics)
    assert Map.has_key?(row.metrics, "isolated_entity_rate")
    assert Map.has_key?(row.metrics, "edges_per_entity")
  end
end
