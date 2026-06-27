defmodule Magus.Plan.Task.Changes.NotifyTaskCompletion do
  @moduledoc """
  Fires on the update action when a task's status transitions to :done.

  When the status changes to :done AND the task was assigned by a different agent
  than the one completing it (i.e. assigned_by != assigned_to), this change creates
  an `:agent_message` inbox event on the assigning agent's inbox (inside the
  transaction via `after_action`). The assigner picks the event up on its next
  heartbeat-driven AgentRun.

  Self-assigned tasks (same agent assigns and completes) do NOT trigger notification.
  """

  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, context) do
    old_status = Ash.Changeset.get_data(changeset, :status)
    actor = context.actor

    changeset
    |> Ash.Changeset.after_action(fn _cs, task ->
      if transitioning_to_done?(changeset, old_status, task) do
        notify_assigner(task, actor)
      end

      {:ok, task}
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp transitioning_to_done?(changeset, old_status, task) do
    # Plan tasks (no conversation_id) never notify: the agent-assignment inbox
    # event is conversation-scoped and `source_id` would be blank for them.
    not is_nil(task.conversation_id) and
      task.status == :done and
      Ash.Changeset.changing_attribute?(changeset, :status) and
      old_status != :done and
      not is_nil(task.assigned_by_custom_agent_id) and
      task.assigned_by_custom_agent_id != task.assigned_to_custom_agent_id
  end

  # ---------------------------------------------------------------------------
  # Inbox Event (after_action - inside transaction)
  # ---------------------------------------------------------------------------

  defp notify_assigner(task, actor) do
    assigner_id = task.assigned_by_custom_agent_id

    assigned_agent_name =
      case Magus.Agents.get_custom_agent(assigner_id, authorize?: false) do
        {:ok, _agent} ->
          # We want the completer's name, not the assigner's
          get_completer_name(task.assigned_to_custom_agent_id)

        _ ->
          "another agent"
      end

    idempotency_key = "task_done:#{task.id}"

    summary =
      if task.result_summary do
        "Completed by #{assigned_agent_name}: #{String.slice(task.result_summary, 0, 200)}"
      else
        "Completed by #{assigned_agent_name}"
      end

    attrs = %{
      agent_id: assigner_id,
      event_type: :agent_message,
      urgency: :immediate,
      title: "Task completed: #{task.title}",
      summary: summary,
      source_type: :conversation,
      source_id: to_string(task.conversation_id),
      payload: %{
        task_id: task.id,
        task_title: task.title,
        conversation_id: task.conversation_id,
        completed_by_agent_id: task.assigned_to_custom_agent_id,
        result_summary: task.result_summary
      },
      idempotency_key: idempotency_key
    }

    case create_inbox_event(attrs, actor) do
      {:ok, _event} ->
        Logger.debug(
          "NotifyTaskCompletion: created agent_message event for assigner #{assigner_id} " <>
            "(task #{task.id})"
        )

      {:error,
       %Ash.Error.Invalid{
         errors: [%Ash.Error.Changes.InvalidChanges{message: "has already been taken"} | _]
       }} ->
        Logger.debug(
          "NotifyTaskCompletion: duplicate task_done event skipped for agent #{assigner_id} " <>
            "(task #{task.id})"
        )

      {:error, reason} ->
        Logger.warning(
          "NotifyTaskCompletion: failed to create agent_message event for agent #{assigner_id}: " <>
            inspect(reason)
        )
    end
  rescue
    e ->
      Logger.warning(
        "NotifyTaskCompletion inbox event error: #{inspect(e)}\n" <>
          Exception.format_stacktrace(__STACKTRACE__)
      )
  end

  defp create_inbox_event(attrs, actor) do
    case actor do
      %Magus.Accounts.User{} = user ->
        Magus.Agents.create_inbox_event(attrs, actor: user)

      _ ->
        # Fall back to authorize?: false for AI actor or nil
        Ash.create(Magus.Agents.AgentInboxEvent, attrs, authorize?: false)
    end
  end

  defp get_completer_name(nil), do: "another agent"

  defp get_completer_name(agent_id) do
    case Magus.Agents.get_custom_agent(agent_id, authorize?: false) do
      {:ok, agent} -> agent.name
      _ -> "another agent"
    end
  end
end
