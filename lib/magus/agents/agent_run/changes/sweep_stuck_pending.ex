defmodule Magus.Agents.AgentRun.Changes.SweepStuckPending do
  @moduledoc """
  Oban-triggered change that sweeps agent runs stuck in `:pending`.

  A `:pending` run should normally be picked up almost immediately by
  `RunOrchestrator.maybe_start_next/1` right after enqueue. A run still
  `:pending` after 15 minutes (see `AgentRun.is_stuck_pending`, which gates
  the Oban trigger) means that nudge was lost somewhere (e.g. a node
  restart between enqueue and claim, or a crashed orchestrator call).

  This change re-evaluates each candidate and either:

  1. Re-nudges the claim loop (`RunOrchestrator.maybe_start_next/1`) when
     the run is younger than `@stuck_timeout_hours` (default 6h) — this
     no-ops when the target has no free capacity, and otherwise gets the
     run running again; or
  2. Times the run out, unlinks any inbox events pointing at it, and emits
     a `run.failed` signal to the source conversation, once it's been
     pending for `@stuck_timeout_hours` or more — a hard backstop against
     runs that can never be claimed (e.g. a permanently gone target).
  """

  use Ash.Resource.Change

  require Logger

  alias Magus.Agents.Support.AutonomyTrace
  alias Magus.Agents.Support.FailureStreak
  alias Magus.Agents.Telemetry

  @stuck_timeout_hours 6

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, run ->
      case Ash.get(Magus.Agents.AgentRun, run.id, authorize?: false) do
        {:ok, %{status: :pending} = current} ->
          if DateTime.diff(DateTime.utc_now(), current.inserted_at, :hour) >=
               @stuck_timeout_hours do
            Logger.warning(
              "SweepStuckPending: timing out run #{current.id} pending > #{@stuck_timeout_hours}h"
            )

            Magus.Agents.timeout_agent_run(current, authorize?: false)
            Telemetry.run_event(:timed_out, current)
            Magus.Agents.AgentRunHelpers.unlink_linked_inbox_events(current)

            Magus.Agents.Signals.run_failed(to_string(current.source_conversation_id), %{
              run_id: to_string(current.id),
              status: "timed_out",
              kind: to_string(current.kind),
              objective: String.slice(current.objective || "", 0, 200),
              target_agent_id: current.target_agent_id,
              target_conversation_id: current.target_conversation_id,
              request_id: current.request_id,
              error: "Run stuck in pending"
            })

            AutonomyTrace.log(
              current.target_agent_id,
              current.initiator_user_id,
              :run_timed_out,
              "Run stuck in pending > #{@stuck_timeout_hours}h",
              %{run_id: current.id, source: current.source}
            )

            if current.target_agent_id,
              do: FailureStreak.check_and_escalate(current.target_agent_id)
          else
            # Lost maybe_start_next (e.g. node restart between enqueue and
            # claim): nudge the claim loop; it no-ops when capacity is full.
            Magus.Agents.RunOrchestrator.maybe_start_next(current.target_conversation_id)
          end

        _ ->
          :ok
      end

      {:ok, run}
    end)
  end
end
