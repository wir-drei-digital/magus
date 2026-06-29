defmodule Magus.SuperBrain.SuperGraphMetricsTest do
  use Magus.ResourceCase, async: false

  alias Magus.SuperBrain.SuperGraph

  test "mark_built persists a metrics map" do
    user = generate(user())

    {:ok, row} =
      SuperGraph
      |> Ash.Changeset.for_create(:create, %{
        accessor_type: :user,
        user_id: user.id,
        workspace_id: nil,
        graph_name: "super:user:#{user.id}"
      })
      |> Ash.create(authorize?: false)

    {:ok, built} =
      row
      |> Ash.Changeset.for_update(:mark_built, %{
        read_set_snapshot: [],
        canonical_entity_count: 3,
        canonical_edge_count: 2,
        last_build_duration_ms: 5,
        metrics: %{"isolated_entity_rate" => 0.0, "contested_edge_count" => 1}
      })
      |> Ash.update(authorize?: false)

    assert built.metrics["contested_edge_count"] == 1
  end
end
