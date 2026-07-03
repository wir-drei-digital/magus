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
    test "nudges a 20-minute-old pending run without timing it out", %{parent: parent} do
      run =
        sub_agent_run(source_conversation_id: parent.id, objective: "Nudge me")
        |> backdate_inserted_at(20)

      {:ok, _} =
        run
        |> Ash.Changeset.for_update(:sweep_stuck_pending, %{})
        |> Ash.update(authorize?: false)

      {:ok, updated} = Magus.Agents.get_agent_run(run.id, authorize?: false)

      # Nudge path: not timed out. Without a registered InstanceManager,
      # maybe_start_next/1 claims the run and then requeues it on
      # `registry_unavailable`, landing back on :pending.
      refute updated.status == :timed_out
      assert updated.status == :pending
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
