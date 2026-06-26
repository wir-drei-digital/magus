defmodule Magus.Agents.Tools.Jobs.ListJobs do
  @moduledoc """
  Tool for listing all jobs in a conversation.

  Returns job names, descriptions, statuses, schedules, and timing information.
  By default, stopped jobs are excluded unless explicitly requested.

  ## Usage with Jido AI

      tools = [Magus.Agents.Tools.Jobs.ListJobs]
      tool_contexts = %{
        Magus.Agents.Tools.Jobs.ListJobs => %{
          conversation_id: conversation.id
        }
      }
  """

  use Jido.Action,
    name: "list_jobs",
    description: "List all jobs for this conversation with their status and schedule.",
    schema: [
      include_stopped: [
        type: :boolean,
        required: false,
        default: false,
        doc: "Include stopped jobs in the list"
      ]
    ]

  require Logger

  import Magus.Agents.Tools.Jobs.Helpers,
    only: [
      validate_context: 2,
      ai_actor: 0,
      format_datetime: 2,
      format_schedule: 1,
      get_timezone: 2
    ]

  import Magus.Agents.Tools.Helpers, only: [get_param: 3]

  @doc "User-friendly display name shown in the UI when this tool is executing"
  def display_name, do: "Listing jobs..."

  @doc "Generate a human-readable summary of the tool output for UI display"
  def summarize_output(%{count: 0}), do: "No jobs found"
  def summarize_output(%{count: count}), do: "Found #{count} jobs"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id]) do
      {:ok, ctx} ->
        Logger.debug("ListJobs: executing", conversation_id: ctx.conversation_id)
        list_jobs(params, ctx, context)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp list_jobs(params, ctx, context) do
    case fetch_jobs(ctx.conversation_id, get_param(params, :include_stopped, false) == true) do
      {:ok, jobs} ->
        timezone = get_timezone(context, nil)

        formatted =
          Enum.map(jobs, fn job ->
            %{
              name: job.name,
              description: job.description,
              status: job.status,
              schedule_type: job.schedule_type,
              schedule: format_schedule(job),
              next_run_at: format_datetime(job.next_run_at, timezone),
              last_run_at: format_datetime(job.last_run_at, timezone),
              memory_name: job.memory_name
            }
          end)

        {:ok,
         %{
           count: length(formatted),
           jobs: formatted
         }}

      {:error, error} ->
        Logger.error("ListJobs: failed - #{inspect(error)}")
        {:ok, %{error: "Failed to list jobs: #{inspect(error)}"}}
    end
  end

  defp fetch_jobs(conversation_id, true = _include_stopped) do
    Magus.Workflows.list_all_jobs_for_conversation(conversation_id, actor: ai_actor())
  end

  defp fetch_jobs(conversation_id, false = _include_stopped) do
    Magus.Workflows.list_jobs_for_conversation(conversation_id, actor: ai_actor())
  end
end
