defmodule Magus.Agents.AgentRunHelpers do
  @moduledoc """
  Cross-cutting helpers for AgentRun lifecycle side effects shared between
  `AgentRunCompletionPlugin` (normal completion / failure paths) and
  `AgentRun.Changes.CleanupStale` (Oban-driven timeout path).

  Keeps the AgentInboxEvent linkage cleanup behavior consistent: any time a
  run reaches a terminal state without a successful completion, linked
  events get unlinked (`agent_run_id` cleared) so the next heartbeat can
  reconsider them.
  """

  require Ash.Query
  require Logger

  @doc """
  Unlinks any AgentInboxEvents pointing at the given run by clearing
  `agent_run_id`. Safe to call from after_action and Oban-triggered code
  paths. Logs and returns `:ok` on read errors.

  Filters to non-terminal statuses (`:pending, :waiting, :processing`) so
  already-resolved/dismissed/expired events are left alone. Terminal
  events keep their historical `agent_run_id` for audit purposes.
  """
  @spec unlink_linked_inbox_events(map() | %{id: term()}) :: :ok
  def unlink_linked_inbox_events(%{id: run_id}) when not is_nil(run_id) do
    Magus.Agents.AgentInboxEvent
    |> Ash.Query.filter(agent_run_id == ^run_id and status in [:pending, :waiting, :processing])
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn event ->
      Magus.Agents.unlink_event_from_run(event, authorize?: false)
    end)

    :ok
  rescue
    e ->
      Logger.warning(
        "AgentRunHelpers: failed to unlink inbox events for run #{inspect(run_id)}: #{Exception.message(e)}"
      )

      :ok
  end

  def unlink_linked_inbox_events(_), do: :ok
end
