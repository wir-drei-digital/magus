defmodule Magus.Agents.Tools.Jobs.StopJob do
  @moduledoc """
  Tool for permanently stopping a job.

  Stopped jobs will no longer run, but their history is preserved.
  This is a soft delete - the job record remains in the database.

  ## Usage with Jido AI

      tools = [Magus.Agents.Tools.Jobs.StopJob]
      tool_contexts = %{
        Magus.Agents.Tools.Jobs.StopJob => %{
          conversation_id: conversation.id
        }
      }
  """

  use Jido.Action,
    name: "stop_job",
    description:
      "Stop a job permanently. The job will no longer run but its history is preserved.",
    schema: [
      name: [
        type: :string,
        required: true,
        doc: "Name of the job to stop"
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
  def display_name, do: "Stopping job..."

  @doc "Generate a human-readable summary of the tool output for UI display"
  def summarize_output(%{status: "stopped", name: name}), do: "Stopped: #{name}"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id]) do
      {:ok, ctx} ->
        name = get_param(params, :name)
        Logger.debug("StopJob: executing", name: name)
        stop_job(name, ctx)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp stop_job(name, ctx) do
    case find_job_by_name(ctx.conversation_id, name) do
      {:ok, job} ->
        if job.status == :stopped do
          {:ok, %{error: "Job '#{name}' is already stopped."}}
        else
          do_stop(job, name)
        end

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp do_stop(job, name) do
    case Magus.Workflows.stop_job(job, actor: ai_actor()) do
      {:ok, _} ->
        Logger.info("StopJob: stopped", name: name, id: job.id)

        {:ok,
         %{
           status: "stopped",
           name: name,
           message: "Job has been stopped and will no longer run."
         }}

      {:error, error} ->
        message = extract_error_message(error)
        Logger.warning("StopJob: failed - #{message}")
        {:ok, %{error: "Failed to stop job: #{message}"}}
    end
  end
end
