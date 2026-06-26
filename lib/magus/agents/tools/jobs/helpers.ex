defmodule Magus.Agents.Tools.Jobs.Helpers do
  @moduledoc """
  Helper functions specific to job tools.

  For shared helpers (context extraction, error handling, etc.),
  see `Magus.Agents.Tools.Helpers`.
  """

  require Logger

  # Re-export shared helpers for convenience
  defdelegate get_context_value(context, key), to: Magus.Agents.Tools.Helpers
  defdelegate extract_error_message(error), to: Magus.Agents.Tools.Helpers
  defdelegate ai_actor(), to: Magus.Agents.Tools.Helpers
  defdelegate validate_context(context, required_keys), to: Magus.Agents.Tools.Helpers

  @doc """
  Formats a datetime for display in the specified timezone.

  ## Examples

      iex> format_datetime(~U[2024-01-15 10:30:00Z], "America/New_York")
      "2024-01-15 05:30 EST"

      iex> format_datetime(nil, "UTC")
      nil
  """
  @spec format_datetime(DateTime.t() | nil, String.t() | nil) :: String.t() | nil
  def format_datetime(nil, _timezone), do: nil

  def format_datetime(dt, timezone) do
    tz = timezone || "UTC"

    case DateTime.shift_zone(dt, tz) do
      {:ok, shifted} ->
        Calendar.strftime(shifted, "%Y-%m-%d %H:%M %Z")

      {:error, _} ->
        # Fallback to UTC if timezone is invalid
        Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
    end
  end

  @doc """
  Parses an ISO8601 datetime string.

  ## Examples

      iex> parse_datetime("2024-01-15T10:30:00Z")
      ~U[2024-01-15 10:30:00Z]

      iex> parse_datetime(nil)
      nil

      iex> parse_datetime("invalid")
      nil
  """
  @spec parse_datetime(String.t() | nil) :: DateTime.t() | nil
  def parse_datetime(nil), do: nil

  def parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  @doc """
  Finds a job by name within a conversation.
  Returns {:ok, job} or {:error, message}.
  """
  @spec find_job_by_name(String.t(), String.t()) :: {:ok, struct()} | {:error, String.t()}
  def find_job_by_name(conversation_id, name) do
    case Magus.Workflows.list_jobs_for_conversation(conversation_id, actor: ai_actor()) do
      {:ok, jobs} ->
        case Enum.find(jobs, &(&1.name == name)) do
          nil -> {:error, "Job '#{name}' not found"}
          job -> {:ok, job}
        end

      {:error, error} ->
        {:error, "Failed to find job: #{extract_error_message(error)}"}
    end
  end

  @doc """
  Formats a job's schedule for display.
  """
  @spec format_schedule(struct()) :: String.t()
  def format_schedule(job) do
    case job.schedule_type do
      :cron ->
        local_cron = job.cron_expression_local || job.cron_expression
        "#{local_cron} (#{job.user_timezone || "UTC"})"

      :one_time ->
        "Once at #{format_datetime(job.scheduled_at, job.user_timezone)}"
    end
  end

  @doc """
  Gets the timezone to use for display.

  Checks in order:
  1. Job's stored user_timezone (set when job was created)
  2. Falls back to UTC

  Note: The tool context only contains user_id, not the full user struct,
  so we rely on the job's stored timezone which was captured at creation time.
  """
  @spec get_timezone(map(), struct() | nil) :: String.t()
  def get_timezone(_context, job) when is_map(job) do
    job_tz = Map.get(job, :user_timezone)

    if job_tz && job_tz != "" do
      job_tz
    else
      "UTC"
    end
  end

  def get_timezone(_context, nil), do: "UTC"

  @doc """
  Maximum number of active jobs allowed per user.
  """
  @spec max_jobs_per_user() :: integer()
  def max_jobs_per_user do
    Application.get_env(:magus, Magus.Workflows)[:max_jobs_per_user] || 10
  end
end
