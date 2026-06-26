defmodule Magus.SuperBrain.SuperGraphTest do
  use Magus.ResourceCase, async: false

  alias Magus.SuperBrain.SuperGraph

  describe "create + upsert" do
    test "creates a row for a user accessor" do
      user = generate(user())

      attrs = %{
        accessor_type: :user,
        user_id: user.id,
        workspace_id: nil,
        graph_name: "super:user:#{user.id}",
        last_build_status: :pending
      }

      assert {:ok, row} = Ash.create(SuperGraph, attrs, authorize?: false)
      assert row.accessor_type == :user
      assert row.user_id == user.id
      assert row.workspace_id == nil
      assert row.graph_name == "super:user:#{user.id}"
      assert row.last_build_status == :pending
      assert row.canonical_entity_count == 0
    end

    test "creates a row for a workspace accessor" do
      user = generate(user())
      workspace = generate(workspace(actor: user))

      attrs = %{
        accessor_type: :workspace,
        user_id: user.id,
        workspace_id: workspace.id,
        graph_name: "super:workspace:#{workspace.id}:#{user.id}",
        last_build_status: :pending
      }

      assert {:ok, row} = Ash.create(SuperGraph, attrs, authorize?: false)
      assert row.accessor_type == :workspace
      assert row.workspace_id == workspace.id
    end

    test "enforces uniqueness on (accessor_type, user_id, workspace_id)" do
      user = generate(user())

      attrs = %{
        accessor_type: :user,
        user_id: user.id,
        workspace_id: nil,
        graph_name: "super:user:#{user.id}",
        last_build_status: :pending
      }

      assert {:ok, _} = Ash.create(SuperGraph, attrs, authorize?: false)
      assert {:error, _} = Ash.create(SuperGraph, attrs, authorize?: false)
    end
  end

  describe "mark_building / mark_built / mark_failed" do
    setup do
      user = generate(user())

      {:ok, row} =
        Ash.create(
          SuperGraph,
          %{
            accessor_type: :user,
            user_id: user.id,
            workspace_id: nil,
            graph_name: "super:user:#{user.id}",
            last_build_status: :pending
          },
          authorize?: false
        )

      {:ok, row: row}
    end

    test "mark_building flips status without touching last_built_at", %{row: row} do
      {:ok, updated} = Ash.update(row, %{}, action: :mark_building, authorize?: false)
      assert updated.last_build_status == :building
      assert updated.last_built_at == nil
    end

    test "mark_built records timestamp + counts + duration", %{row: row} do
      attrs = %{
        last_build_duration_ms: 2500,
        read_set_snapshot: [
          %{"graph_name" => "brain:abc", "snapshot_at" => "2026-05-25T00:00:00Z"}
        ],
        canonical_entity_count: 12,
        canonical_edge_count: 18
      }

      {:ok, updated} = Ash.update(row, attrs, action: :mark_built, authorize?: false)
      assert updated.last_build_status == :ok
      assert updated.last_built_at != nil
      assert updated.canonical_entity_count == 12
      assert updated.canonical_edge_count == 18
      assert updated.last_build_duration_ms == 2500
    end

    test "mark_failed records error", %{row: row} do
      {:ok, updated} =
        Ash.update(row, %{last_error: "FalkorDB unreachable"},
          action: :mark_failed,
          authorize?: false
        )

      assert updated.last_build_status == :failed
      assert updated.last_error == "FalkorDB unreachable"
    end
  end
end
