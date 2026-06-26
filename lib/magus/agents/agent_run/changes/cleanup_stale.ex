defmodule Magus.Agents.AgentRun.Changes.CleanupStale do
  @moduledoc """
  Oban-triggered change that cleans up stale agent runs.

  A run is stale when it's been in :running status with no heartbeat for 2+ minutes.
  Actions:
  1. Mark run as :timed_out
  2. Cancel target conversation agent if running
  3. Emit timeout event to source conversation
  """

  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, run ->
      case Ash.get(Magus.Agents.AgentRun, run.id, authorize?: false) do
        {:ok, %{status: :running}} ->
          Logger.warning(
            "Cleaning up stale agent run #{run.id} for source #{run.source_conversation_id}"
          )

          Magus.Agents.timeout_agent_run(run, authorize?: false)

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

          Magus.Agents.RunOrchestrator.maybe_start_next(run.target_conversation_id)

        _ ->
          :ok
      end

      {:ok, run}
    end)
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
