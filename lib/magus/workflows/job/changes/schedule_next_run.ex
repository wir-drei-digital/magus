defmodule Magus.Workflows.Job.Changes.ScheduleNextRun do
  @moduledoc """
  Calculates and sets the next_run_at timestamp for a job.

  For cron jobs, uses the cron expression to calculate the next execution time.
  For one-time jobs, uses the scheduled_at time if not already run.
  """

  use Ash.Resource.Change

  alias Oban.Cron.Expression

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    # Use before_action to set next_run_at so it gets persisted to the database
    Ash.Changeset.before_action(changeset, fn changeset ->
      # Build a temporary job struct from the changeset to calculate next_run
      job = build_job_from_changeset(changeset)

      Logger.debug("ScheduleNextRun: calculating",
        schedule_type: job.schedule_type,
        cron_expression: job.cron_expression,
        status: job.status,
        starts_at: job.starts_at,
        ends_at: job.ends_at
      )

      next_run = calculate_next_run(job)

      Logger.debug("ScheduleNextRun: result", next_run_at: next_run)

      Ash.Changeset.force_change_attribute(changeset, :next_run_at, next_run)
    end)
  end

  defp build_job_from_changeset(changeset) do
    # Get attributes from changeset, falling back to data for unchanged attrs
    data = changeset.data || %{}

    %{
      status: Ash.Changeset.get_attribute(changeset, :status) || Map.get(data, :status),
      schedule_type:
        Ash.Changeset.get_attribute(changeset, :schedule_type) || Map.get(data, :schedule_type),
      scheduled_at:
        Ash.Changeset.get_attribute(changeset, :scheduled_at) || Map.get(data, :scheduled_at),
      cron_expression:
        Ash.Changeset.get_attribute(changeset, :cron_expression) ||
          Map.get(data, :cron_expression),
      starts_at: Ash.Changeset.get_attribute(changeset, :starts_at) || Map.get(data, :starts_at),
      ends_at: Ash.Changeset.get_attribute(changeset, :ends_at) || Map.get(data, :ends_at),
      last_run_at:
        Ash.Changeset.get_attribute(changeset, :last_run_at) || Map.get(data, :last_run_at)
    }
  end

  defp calculate_next_run(job) do
    # Don't schedule if job isn't active (nil means not yet set, treat as active for create)
    status = job.status || :active

    if status != :active do
      nil
    else
      case job.schedule_type do
        :one_time ->
          calculate_one_time_next_run(job)

        :cron ->
          calculate_cron_next_run(job)

        _ ->
          nil
      end
    end
  end

  defp calculate_one_time_next_run(job) do
    # For one-time jobs, next_run is scheduled_at if not already run
    if is_nil(job.last_run_at) do
      job.scheduled_at
    else
      nil
    end
  end

  defp calculate_cron_next_run(job) do
    cron_expr_str = job.cron_expression

    if is_nil(cron_expr_str) or cron_expr_str == "" do
      nil
    else
      case Expression.parse(cron_expr_str) do
        {:ok, cron_expr} ->
          now = DateTime.utc_now()
          starts_at = job.starts_at || now

          # Use starts_at if job hasn't started yet
          reference =
            if DateTime.compare(now, starts_at) == :lt do
              starts_at
            else
              now
            end

          next = Expression.next_at(cron_expr, reference)

          # Handle :unknown return from @reboot expressions
          case next do
            :unknown ->
              nil

            next_datetime ->
              # Check if next run is before ends_at
              if job.ends_at && DateTime.compare(next_datetime, job.ends_at) != :lt do
                nil
              else
                next_datetime
              end
          end

        {:error, _} ->
          nil
      end
    end
  end
end
