defmodule Magus.Agents.Tools.Plan.UpdateTask do
  @moduledoc """
  Jido tool for updating an existing task in the conversation's task list.
  """

  use Jido.Action,
    name: "update_task",
    description: """
    Update an existing task. Can change title, description, status, position, assignment, or parent.
    Status values: "open", "in_progress", "done", "cancelled".
    When you complete a task, set status to "done". To assign to the user, set assigned_to to "user".
    """,
    schema: [
      task_id: [type: :string, required: true, doc: "Task ID to update"],
      title: [type: {:or, [:string, nil]}, default: nil, doc: "New title"],
      description: [type: {:or, [:string, nil]}, default: nil, doc: "New description"],
      status: [type: {:or, [:string, nil]}, default: nil, doc: "New status"],
      assigned_to: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "'user' or 'agent'"
      ],
      position: [type: {:or, [:integer, nil]}, default: nil, doc: "New position"],
      parent_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Move to parent (or null for top-level)"
      ],
      due_at: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Due date as ISO8601 datetime string"
      ],
      recurrence: [
        type: {:or, [:map, nil]},
        default: nil,
        doc: "Recurrence pattern: %{frequency: daily|weekly|monthly, interval: 1}"
      ]
    ]

  require Logger

  alias Magus.Agents.Signals

  import Magus.Agents.Tools.Helpers,
    only: [get_param: 2, validate_context: 2, ai_actor: 0, extract_error_message: 1]

  def display_name, do: "Updating task..."

  def summarize_output(%{title: title, status: status}), do: "Updated: #{title} (#{status})"
  def summarize_output(%{title: title}), do: "Updated: #{title}"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Updated"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id, :user_id]) do
      {:ok, ctx} ->
        task_id = get_param(params, :task_id)
        Signals.emit_tool_progress(context, :updating, %{task_id: task_id})
        update_task(task_id, params, ctx)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp update_task(task_id, params, ctx) do
    case Magus.Plan.get_task(task_id, actor: ai_actor()) do
      {:ok, task} ->
        if task.conversation_id != ctx.conversation_id do
          {:ok, %{error: "Task not found in this conversation"}}
        else
          apply_updates(task, params, ctx)
        end

      {:error, _} ->
        {:ok, %{error: "Task not found"}}
    end
  end

  defp apply_updates(task, params, ctx) do
    attrs = build_attrs(params, ctx)

    case Magus.Plan.update_task(task, attrs, actor: ai_actor()) do
      {:ok, updated} ->
        Logger.debug("UpdateTask: updated", id: updated.id, status: updated.status)

        {:ok,
         %{
           task_id: updated.id,
           title: updated.title,
           status: updated.status,
           assigned_to: assigned_to_label(updated),
           completed_by: updated.completed_by
         }}

      {:error, error} ->
        message = extract_error_message(error)
        Logger.warning("UpdateTask: failed - #{message}")
        {:ok, %{error: message}}
    end
  end

  defp build_attrs(params, ctx) do
    []
    |> maybe_add(:title, get_param(params, :title))
    |> maybe_add(:description, get_param(params, :description))
    |> maybe_add(:status, parse_status(get_param(params, :status)))
    |> maybe_add(:position, get_param(params, :position))
    |> maybe_add(:parent_id, get_param(params, :parent_id))
    |> maybe_add(:due_at, parse_due_at(get_param(params, :due_at)))
    |> maybe_add(:recurrence, get_param(params, :recurrence))
    |> add_assignment(get_param(params, :assigned_to), ctx.user_id)
    |> Map.new()
  end

  defp maybe_add(attrs, _key, nil), do: attrs
  defp maybe_add(attrs, key, value), do: [{key, value} | attrs]

  defp add_assignment(attrs, "user", user_id),
    do: [{:assigned_to_user_id, user_id}, {:assigned_to_agent, nil} | attrs]

  defp add_assignment(attrs, "agent", _user_id),
    do: [{:assigned_to_agent, "assistant"}, {:assigned_to_user_id, nil} | attrs]

  defp add_assignment(attrs, _assigned_to, _user_id), do: attrs

  defp parse_due_at(nil), do: nil
  defp parse_due_at(%DateTime{} = dt), do: dt

  defp parse_due_at(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_due_at(_), do: nil

  defp parse_status(nil), do: nil
  defp parse_status(status) when is_atom(status), do: status

  defp parse_status(status) when is_binary(status) do
    String.to_existing_atom(status)
  rescue
    ArgumentError -> nil
  end

  defp assigned_to_label(%{assigned_to_user_id: id}) when not is_nil(id), do: "user"
  defp assigned_to_label(%{assigned_to_agent: agent}) when not is_nil(agent), do: "agent"
  defp assigned_to_label(_), do: nil
end
