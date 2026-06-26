defmodule Magus.Plan.Task.Changes.NotifyAgentAssignment do
  @moduledoc """
  Fires on task create and update to manage AgentInboxEvent records when a task
  is assigned to a custom agent. The assigned agent picks up the resulting
  inbox event on its next heartbeat-driven AgentRun.

  ## Assignment Scenarios

  - **New assignment** (nil → agent): Create a `:task_assigned` inbox event
  - **Reassignment** (A → B): Dismiss the old event, create a new event
  - **Unassignment** (A → nil): Dismiss old event (cleanup)
  - **No change** (A → A, or nil → nil): Do nothing

  ## Actor Restrictions

  Inbox event creation requires a `%Magus.Accounts.User{}` actor because
  `AgentInboxEvent.create` uses `relate_actor(:user)`. If the actor is an
  AI agent or nil, inbox event operations are skipped.
  """

  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, context) do
    old_agent_id = Ash.Changeset.get_data(changeset, :assigned_to_custom_agent_id)

    actor = context.actor

    changeset
    |> Ash.Changeset.after_action(fn _changeset, task ->
      new_agent_id = task.assigned_to_custom_agent_id
      handle_inbox_events(task, old_agent_id, new_agent_id, actor)
      {:ok, task}
    end)
  end

  # ============================================================================
  # Inbox Event Management (after_action — inside transaction)
  # ============================================================================

  defp handle_inbox_events(_task, same, same, _actor), do: :ok

  defp handle_inbox_events(task, old_agent_id, new_agent_id, actor) do
    case actor do
      %Magus.Accounts.User{} = user ->
        if old_agent_id && old_agent_id != new_agent_id do
          dismiss_old_event(task, old_agent_id, user)
        end

        if new_agent_id do
          create_assignment_event(task, new_agent_id, user)
        end

      _ ->
        Logger.debug(
          "NotifyAgentAssignment: skipping inbox events — actor is not a User " <>
            "(task #{task.id}, agent #{new_agent_id})"
        )
    end
  rescue
    e ->
      Logger.warning(
        "NotifyAgentAssignment inbox event error: #{inspect(e)}\n" <>
          Exception.format_stacktrace(__STACKTRACE__)
      )
  end

  defp create_assignment_event(task, agent_id, user) do
    idempotency_key = "task_assigned:#{task.id}:#{agent_id}"

    attrs = %{
      agent_id: agent_id,
      event_type: :task_assigned,
      urgency: :immediate,
      title: "Task assigned: #{task.title}",
      summary: task.description,
      source_type: :conversation,
      source_id: to_string(task.conversation_id),
      payload: %{
        task_id: task.id,
        task_title: task.title,
        task_description: task.description,
        conversation_id: task.conversation_id,
        assigned_by_custom_agent_id: task.assigned_by_custom_agent_id
      },
      idempotency_key: idempotency_key
    }

    case Magus.Agents.create_inbox_event(attrs, actor: user) do
      {:ok, _event} ->
        Logger.debug(
          "NotifyAgentAssignment: created task_assigned event for agent #{agent_id} " <>
            "(task #{task.id})"
        )

      {:error,
       %Ash.Error.Invalid{
         errors: [%Ash.Error.Changes.InvalidChanges{message: "has already been taken"} | _]
       }} ->
        Logger.debug(
          "NotifyAgentAssignment: duplicate task_assigned event skipped for agent #{agent_id} " <>
            "(task #{task.id})"
        )

      {:error, reason} ->
        Logger.warning(
          "NotifyAgentAssignment: failed to create task_assigned event for agent #{agent_id}: " <>
            inspect(reason)
        )
    end
  end

  defp dismiss_old_event(task, old_agent_id, user) do
    idempotency_key = "task_assigned:#{task.id}:#{old_agent_id}"

    case Magus.Agents.get_event_by_idempotency_key(idempotency_key, actor: user) do
      {:ok, [event | _]} ->
        case Magus.Agents.dismiss_event(event, actor: user) do
          {:ok, _} ->
            Logger.debug(
              "NotifyAgentAssignment: dismissed old task_assigned event for agent #{old_agent_id} " <>
                "(task #{task.id})"
            )

          {:error, reason} ->
            Logger.warning(
              "NotifyAgentAssignment: failed to dismiss old event for agent #{old_agent_id}: " <>
                inspect(reason)
            )
        end

      {:ok, []} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "NotifyAgentAssignment: failed to look up old event for agent #{old_agent_id}: " <>
            inspect(reason)
        )
    end
  end
end
