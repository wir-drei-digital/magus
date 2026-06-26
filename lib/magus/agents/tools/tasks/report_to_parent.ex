defmodule Magus.Agents.Tools.Tasks.ReportToParent do
  @moduledoc """
  Allows sub-agents to send progress updates to the parent conversation.
  Updates are broadcast via PubSub to the parent's UI channel.
  """

  use Jido.Action,
    name: "report_to_parent",
    description: """
    Send a progress update to the parent conversation that spawned you.
    Use this to report interim findings, status updates, or partial results
    during long-running tasks. The parent will see your updates in real-time.
    """,
    schema: [
      status: [
        type: :string,
        required: true,
        doc: "Brief status message describing current progress"
      ],
      progress_percent: [
        type: {:or, [:integer, nil]},
        default: nil,
        doc: "Optional completion percentage (0-100)"
      ]
    ]

  require Logger

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2, get_param: 2]

  alias Magus.Agents.Signals

  def display_name, do: "Reporting to parent..."
  def summarize_output(%{reported: true}), do: "Progress reported"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id]) do
      {:ok, ctx} -> report(params, ctx)
      {:error, message} -> {:ok, %{error: message}}
    end
  end

  defp report(params, ctx) do
    status = get_param(params, :status)
    progress = get_param(params, :progress_percent)

    case find_source_conversation(ctx.conversation_id) do
      {:ok, source_conversation_id, run} ->
        Signals.broadcast_tool_progress(
          source_conversation_id,
          to_string(run.id),
          "sub_agent",
          :progress_report,
          %{
            status: status,
            progress_percent: progress,
            objective: run.objective,
            agent_name: run.metadata["agent_name"]
          }
        )

        # Also update heartbeat to prevent timeout
        Magus.Agents.heartbeat_agent_run(run, authorize?: false)

        {:ok, %{reported: true, status: status}}

      :not_task ->
        {:ok, %{error: "Not running as a sub-agent task"}}
    end
  end

  defp find_source_conversation(target_conversation_id) do
    case Magus.Agents.running_agent_runs_by_target(target_conversation_id, authorize?: false) do
      {:ok, [run | _]} ->
        {:ok, to_string(run.source_conversation_id), run}

      _ ->
        :not_task
    end
  rescue
    e ->
      Logger.warning(
        "ReportToParent: unexpected error finding parent conversation: #{Exception.message(e)}"
      )

      :not_task
  end
end
