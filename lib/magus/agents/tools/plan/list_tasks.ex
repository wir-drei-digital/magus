defmodule Magus.Agents.Tools.Plan.ListTasks do
  @moduledoc """
  Jido tool for listing all tasks in the current conversation's task list.
  """

  use Jido.Action,
    name: "list_tasks",
    description: """
    List all tasks for the current conversation. Returns tasks grouped with their subtasks, including status, assignment, and completion info.

    Pass `brain_page_id` (a page id, or an exact page title; add `brain_id` if the title is ambiguous) to list a brain page's task board instead.
    """,
    schema: [
      brain_page_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc:
          "List this brain page's task board instead of the conversation. Accepts a page id or an exact page title."
      ],
      brain_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Brain to resolve a brain_page_id TITLE in (id, slug, or brain title)"
      ]
    ]

  alias Magus.Agents.Tools.Brain.BrainResolver

  import Magus.Agents.Tools.Helpers,
    only: [
      get_param: 2,
      get_context_value: 2,
      validate_context: 2,
      nilify_blank_params: 2,
      extract_error_message: 1
    ]

  def display_name, do: "Listing tasks..."

  def summarize_output(%{summary: summary}), do: summary
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Listed tasks"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id]) do
      {:ok, ctx} ->
        params = nilify_blank_params(params, [:brain_page_id, :brain_id])

        case get_param(params, :brain_page_id) do
          nil -> list_conversation_tasks(ctx.conversation_id)
          ref -> list_page_tasks(ref, params, context)
        end

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp list_conversation_tasks(conversation_id) do
    case Magus.Plan.tasks_for_conversation(
           conversation_id,
           actor: Magus.Agents.Tools.Helpers.ai_actor()
         ) do
      {:ok, tasks} ->
        grouped = group_tasks(tasks)
        summary = build_summary(tasks)
        {:ok, %{tasks: grouped, summary: summary}}

      {:error, error} ->
        {:ok, %{error: extract_error_message(error)}}
    end
  end

  # Page boards are read AS THE USER (viewer-gated ActorCanAccessTaskPage);
  # page refs resolve like the brain tools (id or exact title).
  defp list_page_tasks(ref, params, context) do
    user = get_context_value(context, :user)

    if is_nil(user) do
      {:ok, %{error: "brain_page_id requires user context. List without brain_page_id instead."}}
    else
      page_params =
        case Ecto.UUID.cast(ref) do
          {:ok, _} -> %{"page_id" => ref}
          :error -> %{"page_title" => ref}
        end

      with {:ok, brain_id} <- BrainResolver.resolve_brain_id(context, params),
           {:ok, page} <- BrainResolver.resolve_page(context, page_params, brain_id),
           {:ok, tasks} <- Magus.Plan.tasks_for_plan(page.id, actor: user) do
        {:ok,
         %{
           tasks: group_tasks(tasks),
           summary: build_summary(tasks),
           brain_page_id: page.id,
           page_title: page.title
         }}
      else
        {:error, msg} when is_binary(msg) -> {:ok, %{error: msg}}
        {:error, error} -> {:ok, %{error: extract_error_message(error)}}
      end
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
