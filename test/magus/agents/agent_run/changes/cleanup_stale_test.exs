defmodule Magus.Agents.AgentRun.Changes.CleanupStaleTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  require Ash.Query

  setup do
    user = generate(user())
    parent = generate(conversation(actor: user))

    %{user: user, parent: parent}
  end

  describe "cleanup_stale" do
    test "times out a stale running run", %{parent: parent} do
      # Create a run without target_conversation_id to avoid InstanceManager
      # lookup in maybe_cancel_target (registry is disabled in test env).
      # The core behavior under test — timeout transition + signal broadcast — is
      # fully exercised regardless of target_conversation_id.
      run =
        sub_agent_run(
          source_conversation_id: parent.id,
          objective: "Stale task"
        )

      # Start the run so it's in :running status
      {:ok, run} = Magus.Agents.start_agent_run(run, authorize?: false)
      assert run.status == :running

      # Backdate last_heartbeat_at to 3 minutes ago to make it stale
      stale_time = DateTime.add(DateTime.utc_now(), -3, :minute)

      {:ok, run} =
        run
        |> Ash.Changeset.for_update(:heartbeat, %{})
        |> Ash.Changeset.force_change_attribute(:last_heartbeat_at, stale_time)
        |> Ash.update(authorize?: false)

      # Verify it shows up in stale_runs query
      stale =
        Magus.Agents.AgentRun
        |> Ash.Query.for_read(:stale_runs)
        |> Ash.read!(authorize?: false)

      assert Enum.any?(stale, &(&1.id == run.id))

      # Subscribe to PubSub on the source conversation to receive the run.failed signal
      MagusWeb.Endpoint.subscribe("agents:#{parent.id}")

      # Trigger :cleanup_stale action directly
      {:ok, _} =
        run
        |> Ash.Changeset.for_update(:cleanup_stale, %{})
        |> Ash.update(authorize?: false)

      # Verify run is now :timed_out
      {:ok, updated_run} = Magus.Agents.get_agent_run(run.id, authorize?: false)
      assert updated_run.status == :timed_out
      assert updated_run.completed_at != nil
      assert updated_run.duration_ms != nil
      assert updated_run.duration_ms >= 0

      # Verify run.failed signal was broadcast to the source conversation
      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{
          type: "run.failed",
          run_id: _run_id,
          status: "timed_out",
          error: "Run timed out"
        }
      }
    end

    test "writes a :run_timed_out activity log entry when reaping an agent-scoped run",
         %{user: user, parent: parent} do
      agent = generate(custom_agent(user))

      run =
        sub_agent_run(
          source_conversation_id: parent.id,
          target_agent_id: agent.id,
          initiator_user_id: user.id,
          objective: "Stale agent task"
        )

      {:ok, run} = Magus.Agents.start_agent_run(run, authorize?: false)

      stale_time = DateTime.add(DateTime.utc_now(), -3, :minute)

      {:ok, run} =
        run
        |> Ash.Changeset.for_update(:heartbeat, %{})
        |> Ash.Changeset.force_change_attribute(:last_heartbeat_at, stale_time)
        |> Ash.update(authorize?: false)

      {:ok, _} =
        run
        |> Ash.Changeset.for_update(:cleanup_stale, %{})
        |> Ash.update(authorize?: false)

      logs =
        Magus.Agents.AgentActivityLog
        |> Ash.Query.for_read(:for_agent, %{agent_id: agent.id})
        |> Ash.read!(authorize?: false)

      assert Enum.any?(logs, fn log ->
               log.activity_type == :run_timed_out and
                 log.summary == "Run timed out: no liveness for 2m" and
                 log.details["run_id"] == run.id
             end)
    end

    test "no-ops when run is no longer running", %{parent: parent} do
      run =
        sub_agent_run(
          source_conversation_id: parent.id,
          objective: "Already completed task"
        )

      # Start and then complete the run
      {:ok, run} = Magus.Agents.start_agent_run(run, authorize?: false)

      {:ok, run} =
        Magus.Agents.complete_agent_run(run, %{result_text: "All done"}, authorize?: false)

      assert run.status == :complete

      # Backdate heartbeat to make it look stale (even though it's already completed)
      stale_time = DateTime.add(DateTime.utc_now(), -3, :minute)

      {:ok, run} =
        run
        |> Ash.Changeset.for_update(:heartbeat, %{})
        |> Ash.Changeset.force_change_attribute(:last_heartbeat_at, stale_time)
        |> Ash.update(authorize?: false)

      # Subscribe to PubSub — should NOT receive any signal
      MagusWeb.Endpoint.subscribe("agents:#{parent.id}")

      # Trigger :cleanup_stale — should no-op because the guard re-reads and sees :complete
      {:ok, _} =
        run
        |> Ash.Changeset.for_update(:cleanup_stale, %{})
        |> Ash.update(authorize?: false)

      # Verify status is still :complete (unchanged)
      {:ok, updated_run} = Magus.Agents.get_agent_run(run.id, authorize?: false)
      assert updated_run.status == :complete
      assert updated_run.result_text == "All done"

      # Verify no run.failed signal was broadcast
      refute_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "run.failed"}
      }
    end

    test "reaps a dead-process run even when its heartbeat is fresh", %{parent: parent} do
      # target_conversation_id is nil so target_process_alive?/1 short-circuits
      # to false via the `nil` clause: the reap goes through the dead-process
      # branch of should_reap?/3 (InstanceManager registration is unavailable
      # in the test environment; the opt-in duration ceiling is covered by the
      # should_reap?/3 unit tests below). This proves the reap machinery works
      # end-to-end through the `:cleanup_stale` action even when
      # `last_heartbeat_at` is fresh.
      run =
        sub_agent_run(
          source_conversation_id: parent.id,
          objective: "Long-running task"
        )

      {:ok, run} = Magus.Agents.start_agent_run(run, authorize?: false)
      assert run.status == :running

      # started_at 31 minutes ago (past the default 30-minute cap), but
      # last_heartbeat_at kept fresh (simulating an alive, actively-pinging agent).
      old_start = DateTime.add(DateTime.utc_now(), -31, :minute)

      {:ok, run} =
        run
        |> Ash.Changeset.for_update(:heartbeat, %{})
        |> Ash.Changeset.force_change_attribute(:started_at, old_start)
        |> Ash.update(authorize?: false)

      MagusWeb.Endpoint.subscribe("agents:#{parent.id}")

      {:ok, _} =
        run
        |> Ash.Changeset.for_update(:cleanup_stale, %{})
        |> Ash.update(authorize?: false)

      {:ok, updated_run} = Magus.Agents.get_agent_run(run.id, authorize?: false)
      assert updated_run.status == :timed_out

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "run.failed", status: "timed_out"}
      }
    end
  end

  describe "should_reap?/3" do
    alias Magus.Agents.AgentRun.Changes.CleanupStale

    setup do
      now = DateTime.utc_now()
      young_started_at = DateTime.add(now, -5, :minute)
      old_started_at = DateTime.add(now, -31, :minute)

      %{
        now: now,
        young_run: %{started_at: young_started_at},
        old_run: %{started_at: old_started_at}
      }
    end

    test "dead process + young run -> reap", %{now: now, young_run: run} do
      assert CleanupStale.should_reap?(run, false, now)
    end

    test "dead process + old run -> reap", %{now: now, old_run: run} do
      assert CleanupStale.should_reap?(run, false, now)
    end

    test "alive process + young run -> skip", %{now: now, young_run: run} do
      refute CleanupStale.should_reap?(run, true, now)
    end

    test "alive process + old run -> skip (no duration ceiling by default)", %{
      now: now,
      old_run: run
    } do
      refute CleanupStale.should_reap?(run, true, now)
    end

    test "alive process + very old run -> still skipped by default", %{now: now} do
      run = %{started_at: DateTime.add(now, -6 * 60, :minute)}
      refute CleanupStale.should_reap?(run, true, now)
    end

    test "respects an opt-in max_run_duration_minutes ceiling", %{now: now} do
      original = Application.get_env(:magus, :agents, [])
      Application.put_env(:magus, :agents, Keyword.put(original, :max_run_duration_minutes, 5))

      on_exit(fn -> Application.put_env(:magus, :agents, original) end)

      just_under = %{started_at: DateTime.add(now, -4, :minute)}
      just_over = %{started_at: DateTime.add(now, -6, :minute)}

      refute CleanupStale.should_reap?(just_under, true, now)
      assert CleanupStale.should_reap?(just_over, true, now)
    end
  end
end
