defmodule Magus.Agents.Tools.Plan.ListTasks do
  @moduledoc """
  Jido tool for listing all tasks in the current conversation's task list.
  """

  use Jido.Action,
    name: "list_tasks",
    description:
      "List all tasks for the current conversation. Returns tasks grouped with their subtasks, including status, assignment, and completion info.",
    schema: []

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2]

  def display_name, do: "Listing tasks..."

  def summarize_output(%{summary: summary}), do: summary
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Listed tasks"

  @impl true
  def run(_params, context) do
    case validate_context(context, [:conversation_id]) do
      {:ok, ctx} ->
        list_tasks(ctx.conversation_id)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp list_tasks(conversation_id) do
    case Magus.Plan.tasks_for_conversation(
           conversation_id,
           actor: Magus.Agents.Tools.Helpers.ai_actor()
         ) do
      {:ok, tasks} ->
        grouped = group_tasks(tasks)
        summary = build_summary(tasks)
        {:ok, %{tasks: grouped, summary: summary}}

      {:error, error} ->
        {:ok, %{error: inspect(error)}}
    end
  end

  defp group_tasks(tasks) do
    {top_level, subtasks} = Enum.split_with(tasks, &is_nil(&1.parent_id))

    subtasks_by_parent =
      Enum.group_by(subtasks, & &1.parent_id)

    Enum.map(top_level, fn task ->
      children = Map.get(subtasks_by_parent, task.id, [])

      %{
        task_id: task.id,
        title: task.title,
        description: task.description,
        status: task.status,
        position: task.position,
        assigned_to: assigned_to_label(task),
        completed_by: task.completed_by,
        subtasks: Enum.map(children, &format_task/1)
      }
    end)
  end

  defp format_task(task) do
    %{
      task_id: task.id,
      title: task.title,
      description: task.description,
      status: task.status,
      position: task.position,
      assigned_to: assigned_to_label(task),
      completed_by: task.completed_by
    }
  end

  defp build_summary(tasks) do
    total = length(tasks)
    done = Enum.count(tasks, &(&1.status == :done))
    open = Enum.count(tasks, &(&1.status == :open))
    in_progress = Enum.count(tasks, &(&1.status == :in_progress))

    parts =
      [
        if(done > 0, do: "#{done} done"),
        if(in_progress > 0, do: "#{in_progress} in progress"),
        if(open > 0, do: "#{open} open")
      ]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> "#{total} tasks"
      _ -> "#{total} tasks (#{Enum.join(parts, ", ")})"
    end
  end

  defp assigned_to_label(%{assigned_to_user_id: id}) when not is_nil(id), do: "user"
  defp assigned_to_label(%{assigned_to_agent: agent}) when not is_nil(agent), do: "agent"
  defp assigned_to_label(_), do: nil
end
