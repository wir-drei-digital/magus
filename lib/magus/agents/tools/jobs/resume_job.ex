defmodule Magus.Agents.Tools.Jobs.ResumeJob do
  @moduledoc """
  Tool for resuming a paused job.

  Only paused jobs can be resumed. Stopped jobs cannot be resumed.

  ## Usage with Jido AI

      tools = [Magus.Agents.Tools.Jobs.ResumeJob]
      tool_contexts = %{
        Magus.Agents.Tools.Jobs.ResumeJob => %{
          conversation_id: conversation.id
        }
      }
  """

  use Jido.Action,
    name: "resume_job",
    description: "Resume a paused job.",
    schema: [
      name: [
        type: :string,
        required: true,
        doc: "Name of the job to resume"
      ]
    ]

  require Logger

  import Magus.Agents.Tools.Jobs.Helpers,
    only: [
      validate_context: 2,
      extract_error_message: 1,
      ai_actor: 0,
      format_datetime: 2,
      find_job_by_name: 2,
      get_timezone: 2
    ]

  import Magus.Agents.Tools.Helpers, only: [get_param: 2]

  @doc "User-friendly display name shown in the UI when this tool is executing"
  def display_name, do: "Resuming job..."

  @doc "Generate a human-readable summary of the tool output for UI display"
  def summarize_output(%{status: "resumed", name: name}), do: "Resumed: #{name}"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id]) do
      {:ok, ctx} ->
        name = get_param(params, :name)
        Logger.debug("ResumeJob: executing", name: name)
        resume_job(name, ctx, context)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp resume_job(name, ctx, context) do
    case find_job_by_name(ctx.conversation_id, name) do
      {:ok, job} ->
        case job.status do
          :paused ->
            do_resume(job, name, context)

          :active ->
            {:ok, %{error: "Job '#{name}' is already active."}}

          :stopped ->
            {:ok, %{error: "Job '#{name}' is stopped. Stopped jobs cannot be resumed."}}

          :completed ->
            {:ok, %{error: "Job '#{name}' has completed. Create a new job instead."}}
        end

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp do_resume(job, name, context) do
    case Magus.Workflows.resume_job(job, actor: ai_actor()) do
      {:ok, updated} ->
        timezone = get_timezone(context, updated)
        Logger.info("ResumeJob: resumed", name: name, id: job.id)

        {:ok,
         %{
           status: "resumed",
           name: name,
           next_run_at: format_datetime(updated.next_run_at, timezone),
           message: "Job has been resumed and will run at the next scheduled time."
         }}

      {:error, error} ->
        message = extract_error_message(error)
        Logger.warning("ResumeJob: failed - #{message}")
        {:ok, %{error: "Failed to resume job: #{message}"}}
    end
  end
end
