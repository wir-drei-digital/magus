defmodule Magus.Agents.AgentRun.Changes.CleanupStale do
  @moduledoc """
  Oban-triggered change that cleans up stale agent runs.

  A `:running` run is a reap candidate when it's gone 2+ minutes without a
  heartbeat (see `AgentRun.is_stale`, which gates the Oban trigger). But a
  quiet heartbeat doesn't necessarily mean a dead agent: healthy runs ping
  `last_heartbeat_at` at most every ~30s via `Magus.Agents.RunLiveness`, so a
  brief lag (e.g. mid-LLM-call between pings) shouldn't be reaped young. This
  change only actually reaps a candidate run when either:

  1. The target agent process is not alive (`target_process_alive?/1` is
     `false`) — the agent is definitely gone, reap immediately; or
  2. The run has been going for longer than the hard duration cap
     (`max_run_duration_minutes`, default 30 minutes) — even an alive,
     actively-pinging agent gets reaped once it's run too long, as a backstop
     against wedged/runaway runs.

  Otherwise (alive process, within the cap) the reap is skipped and the run's
  heartbeat is touched so the next sweep re-evaluates it fresh.

  When reaping:
  1. Mark run as :timed_out
  2. Cancel target conversation agent if running
  3. Emit timeout event to source conversation
  """

  use Ash.Resource.Change

  require Logger

  alias Magus.Agents.Support.AutonomyTrace
  alias Magus.Agents.Support.FailureStreak
  alias Magus.Agents.Telemetry

  @default_max_run_duration_minutes 30

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, run ->
      case Ash.get(Magus.Agents.AgentRun, run.id, authorize?: false) do
        {:ok, %{status: :running} = current} ->
          if should_reap?(
               current,
               target_process_alive?(current.target_conversation_id),
               DateTime.utc_now()
             ) do
            reap(current)
          else
            # Process is alive and the run is within the duration cap: the
            # agent is likely mid-LLM-call between liveness pings. Refresh
            # the heartbeat so the next sweep re-evaluates instead of reaping.
            Logger.info("CleanupStale: skipping reap of run #{current.id}; target process alive")
            Magus.Agents.heartbeat_agent_run(current, authorize?: false)
          end

        _ ->
          :ok
      end

      {:ok, run}
    end)
  end

  @doc false
  def should_reap?(_run, false = _alive?, _now), do: true

  def should_reap?(%{started_at: %DateTime{} = started_at}, true, now) do
    DateTime.diff(now, started_at, :minute) >= max_run_duration_minutes()
  end

  def should_reap?(_run, true, _now), do: false

  defp max_run_duration_minutes do
    :magus
    |> Application.get_env(:agents, [])
    |> Keyword.get(:max_run_duration_minutes, @default_max_run_duration_minutes)
  end

  defp target_process_alive?(nil), do: false

  defp target_process_alive?(target_conversation_id) do
    case Jido.Agent.InstanceManager.lookup(:conversations, "conv:#{target_conversation_id}") do
      {:ok, pid} -> Process.alive?(pid)
      :error -> false
    end
  rescue
    _ -> false
  end

  defp reap(run) do
    Logger.warning(
      "Cleaning up stale agent run #{run.id} for source #{run.source_conversation_id}"
    )

    Magus.Agents.timeout_agent_run(run, authorize?: false)
    Telemetry.run_event(:timed_out, run)

    maybe_cancel_target(run.target_conversation_id)

    # Mirror the failure path from `AgentRunCompletionPlugin`: unlink
    # any AgentInboxEvents pointing at this run so they don't stay
    # linked to a dead run and can be reconsidered on the next
    # heartbeat.
    Magus.Agents.AgentRunHelpers.unlink_linked_inbox_events(run)

    Magus.Agents.Signals.run_failed(to_string(run.source_conversation_id), %{
      run_id: to_string(run.id),
      status: "timed_out",
      kind: to_string(run.kind),
      objective: String.slice(run.objective || "", 0, 200),
      target_agent_id: run.target_agent_id,
      target_conversation_id: run.target_conversation_id,
      request_id: run.request_id,
      error: "Run timed out"
    })

    AutonomyTrace.log(
      run.target_agent_id,
      run.initiator_user_id,
      :run_timed_out,
      "Run timed out: no liveness for 2m",
      %{
        run_id: run.id,
        source: run.source,
        objective: String.slice(run.objective || "", 0, 200)
      }
    )

    if run.target_agent_id, do: FailureStreak.check_and_escalate(run.target_agent_id)

    Magus.Agents.RunOrchestrator.maybe_start_next(run.target_conversation_id)
  end

  defp maybe_cancel_target(nil), do: :ok

  defp maybe_cancel_target(target_conversation_id) do
    agent_id = "conv:#{target_conversation_id}"

    case Jido.Agent.InstanceManager.lookup(:conversations, agent_id) do
      {:ok, pid} ->
        signal =
          Jido.Signal.new!("message.cancel", %{
            conversation_id: to_string(target_conversation_id)
          })

        Jido.AgentServer.cast(pid, signal)

      :error ->
        :ok
    end
  end
end
