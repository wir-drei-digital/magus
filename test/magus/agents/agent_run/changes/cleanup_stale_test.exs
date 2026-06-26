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
  end
end
