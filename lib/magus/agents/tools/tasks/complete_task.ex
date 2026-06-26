defmodule Magus.Agents.Tools.Tasks.CompleteTask do
  use Jido.Action,
    name: "complete_task",
    description: """
    Mark this task as complete. This stops all scheduled jobs for this task
    and notifies the parent conversation with your summary.
    Call this when you have fulfilled the objective or cannot make further progress.
    """,
    schema: [
      summary: [
        type: :string,
        required: true,
        doc: "Summary of what was accomplished or why the task is ending"
      ],
      result: [
        type: {:or, [:map, nil]},
        default: nil,
        doc: "Optional structured result data"
      ]
    ]

  require Logger

  import Magus.Agents.Tools.Helpers,
    only: [validate_context: 2, get_param: 2, ai_actor: 0]

  def display_name, do: "Completing task..."

  def summarize_output(%{completed: true}), do: "Task completed"
  def summarize_output(%{error: e}), do: "Error: #{e}"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id, :user_id]) do
      {:ok, ctx} -> complete(params, ctx)
      {:error, message} -> {:ok, %{error: message}}
    end
  end

  defp complete(params, ctx) do
    summary = get_param(params, :summary)
    truncated = String.slice(summary, 0, 500)

    stop_jobs(ctx.conversation_id)

    case load_conversation(ctx.conversation_id) do
      {:ok, conversation} ->
        if conversation.parent_conversation_id do
          notify_parent(conversation.parent_conversation_id, truncated, ctx)
        end

      _ ->
        :ok
    end

    {:ok, %{completed: true, summary: truncated}}
  end

  defp stop_jobs(conversation_id) do
    case Magus.Workflows.list_jobs_for_conversation(conversation_id, actor: ai_actor()) do
      {:ok, jobs} ->
        jobs
        |> Enum.filter(&(&1.status in [:active, :paused]))
        |> Enum.each(&Magus.Workflows.stop_job(&1, actor: ai_actor()))

      _ ->
        :ok
    end
  end

  defp notify_parent(parent_id, summary, ctx) do
    Magus.Chat.create_event_message(
      "Task completed: #{summary}",
      parent_id,
      authorize?: false
    )

    Magus.Notifications.create_notification(
      %{
        user_id: ctx.user_id,
        body: summary,
        notification_type: :task_completed,
        target_conversation_id: parent_id
      },
      authorize?: false
    )
  end

  defp load_conversation(conversation_id) do
    Magus.Chat.get_conversation(conversation_id, authorize?: false)
  end
end
