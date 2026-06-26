defmodule Magus.SuperBrain.Workers.MigrationSweeperTest do
  use Magus.ResourceCase, async: false

  use Oban.Testing, repo: Magus.Repo

  alias Magus.SuperBrain.{Migration, SuperGraph}
  alias Magus.SuperBrain.Workers.{BuildSuperFull, MigrationSweeper}

  require Ash.Query

  defp drain_oban_jobs do
    Magus.Repo.delete_all(Oban.Job)
    :ok
  end

  defp create_super_graph!(user, graph_name, status \\ :ok) do
    {:ok, row} =
      Ash.create(
        SuperGraph,
        %{
          accessor_type: :user,
          user_id: user.id,
          workspace_id: nil,
          graph_name: graph_name,
          last_build_status: status
        },
        authorize?: false
      )

    row
  end

  describe "perform/1" do
    test "no SuperGraph rows: no enqueues, telemetry emitted with zeros" do
      drain_oban_jobs()

      :telemetry_test.attach_event_handlers(self(), [
        [:super_brain, :migration, :progress]
      ])

      assert :ok = perform_job(MigrationSweeper, %{})

      assert_received {[:super_brain, :migration, :progress], _ref,
                       %{total_rows: 0, stale_rows: 0, enqueued: 0}, %{current_version: _}}

      refute_enqueued(worker: BuildSuperFull)
    end

    @tag :integration
    test "graph with current marker on CanonicalEntity: not enqueued" do
      user = generate(user())
      graph_name = "super:user:#{user.id}:current_marker_test"
      _ = Magus.Graph.drop(graph_name)
      _ = create_super_graph!(user, graph_name)

      {:ok, _} =
        Magus.Graph.query(
          graph_name,
          "CREATE (:CanonicalEntity {id: 'a', migration_marker: $v}) RETURN 1",
          %{v: Migration.canonical_version()}
        )

      drain_oban_jobs()

      assert :ok = perform_job(MigrationSweeper, %{})

      refute_enqueued(
        worker: BuildSuperFull,
        args: %{"user_id" => user.id}
      )
    end

    @tag :integration
    test "graph with missing marker: enqueues BuildSuperFull" do
      user = generate(user())
      graph_name = "super:user:#{user.id}:missing_marker_test"
      _ = Magus.Graph.drop(graph_name)
      _ = create_super_graph!(user, graph_name)

      {:ok, _} =
        Magus.Graph.query(
          graph_name,
          "CREATE (:CanonicalEntity {id: 'a'}) RETURN 1",
          %{}
        )

      drain_oban_jobs()

      assert :ok = perform_job(MigrationSweeper, %{})

      assert_enqueued(
        worker: BuildSuperFull,
        args: %{
          "accessor_type" => "user",
          "user_id" => user.id,
          "workspace_id" => nil
        }
      )
    end

    @tag :integration
    test "graph with stale marker (< current): enqueues BuildSuperFull" do
      user = generate(user())
      graph_name = "super:user:#{user.id}:stale_marker_test"
      _ = Magus.Graph.drop(graph_name)
      _ = create_super_graph!(user, graph_name)

      stale = Migration.canonical_version() - 1

      {:ok, _} =
        Magus.Graph.query(
          graph_name,
          "CREATE (:CanonicalEntity {id: 'a', migration_marker: $v}) RETURN 1",
          %{v: stale}
        )

      drain_oban_jobs()

      assert :ok = perform_job(MigrationSweeper, %{})

      assert_enqueued(
        worker: BuildSuperFull,
        args: %{"user_id" => user.id}
      )
    end

    test "SuperGraph row with status :building is skipped" do
      user = generate(user())
      _ = create_super_graph!(user, "super:user:#{user.id}:building", :building)

      drain_oban_jobs()

      assert :ok = perform_job(MigrationSweeper, %{})

      refute_enqueued(
        worker: BuildSuperFull,
        args: %{"user_id" => user.id}
      )
    end

    @tag :integration
    test "rate cap: enqueues at most max_enqueues_per_tick per tick" do
      original = Application.get_env(:magus, :super_brain_migration_sweeper, [])

      Application.put_env(:magus, :super_brain_migration_sweeper, max_enqueues_per_tick: 2)

      on_exit(fn ->
        Application.put_env(:magus, :super_brain_migration_sweeper, original)
      end)

      users = for _ <- 1..3, do: generate(user())

      Enum.each(users, fn u ->
        graph_name = "super:user:#{u.id}:rate_cap_test"
        _ = Magus.Graph.drop(graph_name)
        _ = create_super_graph!(u, graph_name)

        {:ok, _} =
          Magus.Graph.query(
            graph_name,
            "CREATE (:CanonicalEntity {id: 'a'}) RETURN 1",
            %{}
          )
      end)

      drain_oban_jobs()

      assert :ok = perform_job(MigrationSweeper, %{})

      enqueued =
        all_enqueued(worker: BuildSuperFull)
        |> Enum.filter(fn j -> Map.get(j.args, "user_id") in Enum.map(users, & &1.id) end)

      assert length(enqueued) == 2
    end
  end
end
