defmodule Magus.SuperBrain.CleanupTest do
  use Magus.ResourceCase, async: false

  alias Magus.SuperBrain.Cleanup
  alias Magus.SuperBrain.{ExtractionBudget, SuperGraph}

  require Ash.Query

  describe "purge_user/1" do
    test "deletes SuperGraph rows for the user" do
      user = generate(user())

      {:ok, _row} =
        Ash.create(
          SuperGraph,
          %{
            accessor_type: :user,
            user_id: user.id,
            workspace_id: nil,
            graph_name: "super:user:#{user.id}",
            last_build_status: :ok
          },
          authorize?: false
        )

      assert {:ok, [_]} =
               SuperGraph
               |> Ash.Query.filter(user_id == ^user.id)
               |> Ash.read(authorize?: false)

      :ok = Cleanup.purge_user(user.id)

      assert {:ok, []} =
               SuperGraph
               |> Ash.Query.filter(user_id == ^user.id)
               |> Ash.read(authorize?: false)
    end

    test "deletes ExtractionBudget rows for the user" do
      user = generate(user())
      date = Date.utc_today()

      :ok = ExtractionBudget.atomic_increment(user.id, date, calls: 1, cost_cents: 1)
      {:ok, _budget} = ExtractionBudget.get_for(user.id, date)

      :ok = Cleanup.purge_user(user.id)

      assert {:ok, nil} = ExtractionBudget.get_for(user.id, date)
    end

    test "leaves other users' rows intact" do
      keeper = generate(user())
      victim = generate(user())

      for u <- [keeper, victim] do
        {:ok, _} =
          Ash.create(
            SuperGraph,
            %{
              accessor_type: :user,
              user_id: u.id,
              workspace_id: nil,
              graph_name: "super:user:#{u.id}",
              last_build_status: :ok
            },
            authorize?: false
          )
      end

      :ok = Cleanup.purge_user(victim.id)

      assert {:ok, [_]} =
               SuperGraph
               |> Ash.Query.filter(user_id == ^keeper.id)
               |> Ash.read(authorize?: false)

      assert {:ok, []} =
               SuperGraph
               |> Ash.Query.filter(user_id == ^victim.id)
               |> Ash.read(authorize?: false)
    end

    test "returns :ok even when no rows or graphs exist for the user" do
      user = generate(user())
      assert :ok = Cleanup.purge_user(user.id)
    end

    @tag :integration
    test "drops the four personal FalkorDB graphs for the user" do
      user = generate(user())

      for graph <- [
            "memories:user:#{user.id}",
            "files:user:#{user.id}",
            "drafts:user:#{user.id}",
            "super:user:#{user.id}"
          ] do
        {:ok, _} =
          Magus.Graph.query(graph, "CREATE (n:Tombstone {marker: 'present'}) RETURN n")
      end

      :ok = Cleanup.purge_user(user.id)

      for graph <- [
            "memories:user:#{user.id}",
            "files:user:#{user.id}",
            "drafts:user:#{user.id}",
            "super:user:#{user.id}"
          ] do
        case Magus.Graph.query(graph, "MATCH (n:Tombstone) RETURN count(n)") do
          {:ok, %{rows: [["0"]]}} -> :ok
          {:ok, %{rows: [[0]]}} -> :ok
          {:error, _graph_unavailable} -> :ok
        end
      end
    end

    @tag :integration
    test "after-action on User destroy invokes purge_user via AccountDeletion" do
      user = generate(user())

      {:ok, _} =
        Ash.create(
          SuperGraph,
          %{
            accessor_type: :user,
            user_id: user.id,
            workspace_id: nil,
            graph_name: "super:user:#{user.id}",
            last_build_status: :ok
          },
          authorize?: false
        )

      :ok = Magus.Accounts.AccountDeletion.execute(user)

      assert {:ok, []} =
               SuperGraph
               |> Ash.Query.filter(user_id == ^user.id)
               |> Ash.read(authorize?: false)
    end
  end
end
