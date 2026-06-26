defmodule Magus.Agents.Context.TaskContext do
  @moduledoc """
  Builds task list context for AI agents.
  Renders all tasks for a conversation as a markdown checklist,
  injected into the system prompt each turn.
  """

  @spec build(Ecto.UUID.t(), keyword()) :: String.t() | nil
  def build(conversation_id, opts \\ [])

  def build(conversation_id, opts) when is_binary(conversation_id) do
    case Magus.Plan.tasks_for_conversation(conversation_id, opts) do
      {:ok, []} -> nil
      {:ok, tasks} -> render(tasks)
      {:error, _} -> nil
    end
  end

  def build(_, _opts), do: nil

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp render(tasks) do
    top_level = Enum.filter(tasks, &is_nil(&1.parent_id))
    subtasks_by_parent = Enum.group_by(Enum.filter(tasks, & &1.parent_id), & &1.parent_id)

    lines =
      Enum.map(top_level, fn task ->
        parent_line = format_task(task, "")
        children = Map.get(subtasks_by_parent, task.id, [])

        child_lines = Enum.map(children, fn subtask -> format_task(subtask, "  ") end)

        [parent_line | child_lines]
      end)
      |> List.flatten()

    """
    ## Tasks

    #{Enum.join(lines, "\n")}

    Use `create_task` to add tasks, `update_task` to change status/assignment, `list_tasks` to see full details with IDs.
    The user can also add and check off tasks directly in the task pane.
    """
    |> String.trim()
  end

  defp format_task(task, indent) do
    checkbox = if task.status == :done, do: "[x]", else: "[ ]"
    meta = build_meta(task)

    meta_str = if meta != [], do: " (#{Enum.join(meta, ", ")})", else: ""

    "#{indent}- #{checkbox} #{task.title}#{meta_str} [id:#{task.id}]"
  end

  defp build_meta(task) do
    assignment =
      cond do
        task.assigned_to_user_id -> "@user"
        task.assigned_to_agent -> "@agent"
        true -> nil
      end

    status_note =
      case task.status do
        :in_progress -> "in progress"
        :cancelled -> "cancelled"
        _ -> nil
      end

    completed_by_note =
      if task.status == :done && task.completed_by do
        "completed by #{task.completed_by}"
      else
        nil
      end

    [assignment, status_note, completed_by_note]
    |> Enum.reject(&is_nil/1)
  end
end
