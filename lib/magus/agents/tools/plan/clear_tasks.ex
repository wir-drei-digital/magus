defmodule Magus.Agents.Tools.Plan.ClearTasks do
  @moduledoc """
  Jido tool for archiving all completed tasks in a conversation.
  """

  use Jido.Action,
    name: "clear_tasks",
    description: """
    Archive all completed (done) tasks in the current conversation.
    Use this when you've finished a batch of work and want a clean slate for the next set of tasks.
    Archived tasks are removed from the task list but preserved in history.
    """,
    schema: []

  require Ash.Query

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2]

  alias Magus.Agents.Signals

  def display_name, do: "Clearing completed tasks..."

  def summarize_output(%{archived: 0}), do: "No completed tasks to archive"
  def summarize_output(%{archived: n}), do: "Archived #{n} completed tasks"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(_params, context) do
    case validate_context(context, [:conversation_id]) do
      {:ok, ctx} ->
        Signals.emit_tool_progress(context, :archiving, %{})
        clear(ctx.conversation_id)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp clear(conversation_id) do
    # Count done tasks before archiving
    done_tasks =
      Magus.Plan.Task
      |> Ash.Query.filter(conversation_id == ^conversation_id and status == :done)
      |> Ash.read!(actor: Magus.Agents.Tools.Helpers.ai_actor())

    count = length(done_tasks)

    if count > 0 do
      Magus.Plan.archive_done_tasks(
        conversation_id,
        actor: Magus.Agents.Tools.Helpers.ai_actor()
      )
    end

    {:ok, %{archived: count, message: "#{count} completed tasks archived"}}
  end
end
