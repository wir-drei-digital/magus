defmodule Magus.Agents.Context.JobsContext do
  @moduledoc """
  Builds active jobs context for AI agents.

  Provides context about active and paused jobs in a conversation so agents
  are aware of existing jobs and avoid creating duplicates.
  """

  require Logger

  @doc """
  Build jobs context for a conversation.

  Returns a formatted string describing active/paused jobs, or nil if none exist.
  """
  @spec build(Ecto.UUID.t(), keyword()) :: String.t() | nil
  def build(conversation_id, opts \\ [])

  def build(conversation_id, opts) when is_binary(conversation_id) do
    case Magus.Workflows.list_jobs_for_conversation(conversation_id, opts) do
      {:ok, []} ->
        nil

      {:ok, jobs} ->
        format_jobs(jobs)

      {:error, error} ->
        Logger.warning("Failed to fetch jobs for context: #{inspect(error)}")
        nil
    end
  end

  def build(_, _), do: nil

  defp format_jobs(jobs) do
    job_lines =
      Enum.map_join(jobs, "\n", fn job ->
        schedule = format_schedule(job)
        status = if job.status == :paused, do: " [PAUSED]", else: ""
        "- **#{job.name}**#{status}: #{schedule}"
      end)

    """
    ## Active Jobs

    This conversation has the following scheduled jobs. Do not create duplicate jobs — update or manage existing ones instead.

    #{job_lines}
    """
    |> String.trim()
  end

  defp format_schedule(job) do
    case job.schedule_type do
      :cron ->
        local_cron = job.cron_expression_local || job.cron_expression
        "#{local_cron} (#{job.user_timezone || "UTC"})"

      :one_time ->
        case job.scheduled_at do
          nil -> "One-time (not yet scheduled)"
          dt -> "Once at #{format_datetime(dt, job.user_timezone)}"
        end
    end
  end

  defp format_datetime(dt, timezone) do
    tz = timezone || "UTC"

    case DateTime.shift_zone(dt, tz) do
      {:ok, shifted} -> Calendar.strftime(shifted, "%Y-%m-%d %H:%M %Z")
      {:error, _} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
    end
  end
end
