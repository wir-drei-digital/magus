defmodule Magus.Agents.AgentRun.SweepStuckPendingTest do
  @moduledoc """
  Tests the stuck-pending sweep: `AgentRun.stuck_pending_runs` read action
  scopes to `:pending` runs older than 15 minutes, and the
  `:sweep_stuck_pending` update either nudges the claim loop (< 6h old) or
  times the run out and unlinks any inbox events pointing at it (>= 6h old).
  """

  use Magus.DataCase, async: false

  import Magus.Generators

  require Ash.Query

  alias Magus.Agents.AgentRun

  setup do
    user = generate(user())
    parent = generate(conversation(actor: user))

    %{user: user, parent: parent}
  end

  defp backdate_inserted_at(run, minutes_ago) do
    backdated = DateTime.add(DateTime.utc_now(), -minutes_ago, :minute)

    AgentRun
    |> Ecto.Query.where([r], r.id == ^run.id)
    |> Magus.Repo.update_all(set: [inserted_at: backdated])

    {:ok, run} = Magus.Agents.get_agent_run(run.id, authorize?: false)
    run
  end

  describe "stuck_pending_runs read action" do
    test "excludes a 5-minute-old pending run and includes a 20-minute-old one",
         %{parent: parent} do
      young =
        sub_agent_run(source_conversation_id: parent.id, objective: "Fresh task")
        |> backdate_inserted_at(5)

      old =
        sub_agent_run(source_conversation_id: parent.id, objective: "Stuck task")
        |> backdate_inserted_at(20)

      stuck =
        AgentRun
        |> Ash.Query.for_read(:stuck_pending_runs)
        |> Ash.read!(authorize?: false)

      stuck_ids = Enum.map(stuck, & &1.id)

      refute young.id in stuck_ids
      assert old.id in stuck_ids
    end
  end

  describe "sweep_stuck_pending" do
    test "nudges a 20-minute-old pending run with a real target", %{user: user, parent: parent} do
      target = generate(conversation(actor: user))

      run =
        sub_agent_run(
          source_conversation_id: parent.id,
          target_conversation_id: target.id,
          objective: "Nudge me"
        )
        |> backdate_inserted_at(20)

      {:ok, _} =
        run
        |> Ash.Changeset.for_update(:sweep_stuck_pending, %{})
        |> Ash.update(authorize?: false)

      {:ok, updated} = Magus.Agents.get_agent_run(run.id, authorize?: false)

      # Nudge path: `maybe_start_next/1` is called with a real target, so it
      # claims the run (status -> :running, started_at/last_heartbeat_at
      # set), then `AgentBootstrap.ensure_conversation_agent` fails with
      # `registry_unavailable` (no InstanceManager registered in tests), and
      # `RunOrchestrator.requeue_run/1` runs the `:requeue` action, which
      # resets status to :pending and clears started_at/last_heartbeat_at
      # (see AgentRun's `:requeue` update). Assert that exact post-state
      # rather than just "not timed out", so this pins the nudge path
      # instead of the nil-target no-op.
      refute updated.status == :timed_out
      assert updated.status == :pending
      assert updated.started_at == nil
      assert updated.last_heartbeat_at == nil
    end

    test "nudge with nil target is a no-op", %{parent: parent} do
      run =
        sub_agent_run(source_conversation_id: parent.id, objective: "Nudge me")
        |> backdate_inserted_at(20)

      assert run.target_conversation_id == nil

      {:ok, _} =
        run
        |> Ash.Changeset.for_update(:sweep_stuck_pending, %{})
        |> Ash.update(authorize?: false)

      {:ok, updated} = Magus.Agents.get_agent_run(run.id, authorize?: false)

      # With no target_conversation_id, `maybe_start_next(nil)` short-circuits
      # to `:ok` immediately, so the run is left exactly as it was: still
      # :pending, and started_at/last_heartbeat_at untouched (nil, since it
      # was never claimed).
      refute updated.status == :timed_out
      assert updated.status == :pending
      assert updated.started_at == nil
      assert updated.last_heartbeat_at == nil
    end

    test "times out a 7-hour-old pending run and unlinks a linked inbox event",
         %{user: user, parent: parent} do
      agent = generate(custom_agent(user))

      run =
        sub_agent_run(source_conversation_id: parent.id, objective: "Long stuck task")
        |> backdate_inserted_at(7 * 60)

      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :mention,
            urgency: :immediate,
            title: "Linked to stuck run",
            source_type: :conversation,
            agent_run_id: run.id
          },
          actor: user
        )

      assert event.agent_run_id == run.id

      MagusWeb.Endpoint.subscribe("agents:#{parent.id}")

      {:ok, _} =
        run
        |> Ash.Changeset.for_update(:sweep_stuck_pending, %{})
        |> Ash.update(authorize?: false)

      {:ok, updated_run} = Magus.Agents.get_agent_run(run.id, authorize?: false)
      assert updated_run.status == :timed_out

      {:ok, updated_event} =
        Ash.get(Magus.Agents.AgentInboxEvent, event.id, authorize?: false)

      assert updated_event.agent_run_id == nil

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{
          type: "run.failed",
          run_id: _run_id,
          status: "timed_out",
          error: "Run stuck in pending"
        }
      }
    end

    test "leaves a young pending run's status untouched when swept directly (no-op path)",
         %{parent: parent} do
      run =
        sub_agent_run(source_conversation_id: parent.id, objective: "Still fresh")

      MagusWeb.Endpoint.subscribe("agents:#{parent.id}")

      {:ok, _} =
        run
        |> Ash.Changeset.for_update(:sweep_stuck_pending, %{})
        |> Ash.update(authorize?: false)

      {:ok, updated} = Magus.Agents.get_agent_run(run.id, authorize?: false)
      refute updated.status == :timed_out

      refute_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "run.failed"}
      }
    end
  end
end
