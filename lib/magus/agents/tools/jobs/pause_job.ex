defmodule Magus.Agents.Tools.Jobs.PauseJob do
  @moduledoc """
  Tool for temporarily pausing a job.

  Paused jobs can be resumed later. Only active jobs can be paused.

  ## Usage with Jido AI

      tools = [Magus.Agents.Tools.Jobs.PauseJob]
      tool_contexts = %{
        Magus.Agents.Tools.Jobs.PauseJob => %{
          conversation_id: conversation.id
        }
      }
  """

  use Jido.Action,
    name: "pause_job",
    description: "Temporarily pause a job. The job can be resumed later.",
    schema: [
      name: [
        type: :string,
        required: true,
        doc: "Name of the job to pause"
      ]
    ]

  require Logger

  import Magus.Agents.Tools.Jobs.Helpers,
    only: [
      validate_context: 2,
      extract_error_message: 1,
      ai_actor: 0,
      find_job_by_name: 2
    ]

  import Magus.Agents.Tools.Helpers, only: [get_param: 2]

  @doc "User-friendly display name shown in the UI when this tool is executing"
  def display_name, do: "Pausing job..."

  @doc "Generate a human-readable summary of the tool output for UI display"
  def summarize_output(%{status: "paused", name: name}), do: "Paused: #{name}"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id]) do
      {:ok, ctx} ->
        name = get_param(params, :name)
        Logger.debug("PauseJob: executing", name: name)
        pause_job(name, ctx)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp pause_job(name, ctx) do
    case find_job_by_name(ctx.conversation_id, name) do
      {:ok, job} ->
        case job.status do
          :active ->
            do_pause(job, name)

          :paused ->
            {:ok, %{error: "Job '#{name}' is already paused."}}

          :stopped ->
            {:ok, %{error: "Job '#{name}' is stopped and cannot be paused."}}

          :completed ->
            {:ok, %{error: "Job '#{name}' has completed and cannot be paused."}}
        end

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp do_pause(job, name) do
    case Magus.Workflows.pause_job(job, actor: ai_actor()) do
      {:ok, _} ->
        Logger.info("PauseJob: paused", name: name, id: job.id)

        {:ok,
         %{
           status: "paused",
           name: name,
           message: "Job has been paused. Use resume_job to restart it."
         }}

      {:error, error} ->
        message = extract_error_message(error)
        Logger.warning("PauseJob: failed - #{message}")
        {:ok, %{error: "Failed to pause job: #{message}"}}
    end
  end
end
