defmodule Magus.Agents.Tools.Jobs.CreateJob do
  @moduledoc """
  Tool for creating a new scheduled job in a conversation.

  Jobs can be scheduled via cron expressions for recurring execution
  or as one-time scheduled tasks. Each job triggers the AI agent
  with a specific prompt when executed.

  ## Usage with Jido AI

      tools = [Magus.Agents.Tools.Jobs.CreateJob]
      tool_contexts = %{
        Magus.Agents.Tools.Jobs.CreateJob => %{
          user_id: user.id,
          conversation_id: conversation.id
        }
      }
  """

  use Jido.Action,
    name: "create_job",
    description: """
    Schedule a recurring or one-time job that will trigger you with a prompt at the specified times.

    REQUIRED FIELDS BY SCHEDULE TYPE:
    - For schedule_type="cron": You MUST provide cron_expression AND ends_at
    - For schedule_type="one_time": You MUST provide scheduled_at

    CRON EXPRESSION FORMAT: "minute hour day-of-month month day-of-week"
    Examples:
    - "0 9 * * *" = every day at 9:00 AM UTC
    - "0 9 * * 1-5" = weekdays at 9:00 AM UTC
    - "0 */2 * * *" = every 2 hours

    All times should be in UTC. The ends_at prevents jobs from running indefinitely.
    """,
    schema: [
      name: [
        type: :string,
        required: true,
        doc: "Human-readable name for the job"
      ],
      description: [
        type: :string,
        required: false,
        doc: "Description of what the job does"
      ],
      trigger_prompt: [
        type: :string,
        required: true,
        doc: "The prompt you will receive when the job triggers"
      ],
      memory_name: [
        type: :string,
        required: false,
        doc: "Name of memory to load when triggered (defaults to most recent)"
      ],
      schedule_type: [
        type: :string,
        required: true,
        doc: "Type of schedule: 'cron' for recurring, 'one_time' for single execution"
      ],
      cron_expression: [
        type: :string,
        required: false,
        doc:
          "REQUIRED for cron jobs. Cron expression in UTC (e.g., '0 9 * * *' for 9 AM UTC daily)"
      ],
      cron_expression_local: [
        type: :string,
        required: false,
        doc: "Optional: Original cron in user's timezone (for display purposes)"
      ],
      scheduled_at: [
        type: :string,
        required: false,
        doc: "REQUIRED for one_time jobs. ISO8601 datetime in UTC (e.g., '2026-01-15T14:00:00Z')"
      ],
      starts_at: [
        type: :string,
        required: false,
        doc: "Optional: When the job should start (UTC ISO8601, defaults to now)"
      ],
      ends_at: [
        type: :string,
        required: false,
        doc:
          "REQUIRED for cron jobs. When the job should stop running (UTC ISO8601, e.g., '2026-02-01T00:00:00Z')"
      ]
    ]

  require Logger

  import Magus.Agents.Tools.Jobs.Helpers,
    only: [
      validate_context: 2,
      extract_error_message: 1,
      ai_actor: 0,
      parse_datetime: 1,
      format_datetime: 2,
      get_timezone: 2,
      max_jobs_per_user: 0
    ]

  import Magus.Agents.Tools.Helpers, only: [get_param: 2]

  @doc "User-friendly display name shown in the UI when this tool is executing"
  def display_name, do: "Creating job..."

  @doc "Generate a human-readable summary of the tool output for UI display"
  def summarize_output(%{status: "created", name: name}), do: "Created: #{name}"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id, :user_id]) do
      {:ok, ctx} ->
        name = get_param(params, :name)

        Logger.debug("CreateJob: executing",
          name: name,
          conversation_id: ctx.conversation_id,
          user_id: ctx.user_id
        )

        check_limit_and_create(params, ctx, context)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp check_limit_and_create(params, ctx, context) do
    case Magus.Workflows.list_jobs_for_user(ctx.user_id, actor: ai_actor()) do
      {:ok, jobs} ->
        active_count = Enum.count(jobs, &(&1.status in [:active, :paused]))

        if active_count >= max_jobs_per_user() do
          {:ok,
           %{
             error:
               "You have reached the maximum of #{max_jobs_per_user()} active jobs. Stop some jobs before creating new ones."
           }}
        else
          create_job(params, ctx, context)
        end

      {:error, error} ->
        {:ok, %{error: "Failed to check job limit: #{extract_error_message(error)}"}}
    end
  end

  defp create_job(params, ctx, context) do
    timezone = get_timezone(context, nil)

    attrs = %{
      name: get_param(params, :name),
      description: get_param(params, :description),
      trigger_prompt: get_param(params, :trigger_prompt),
      memory_name: get_param(params, :memory_name),
      schedule_type: parse_schedule_type(get_param(params, :schedule_type)),
      cron_expression: get_param(params, :cron_expression),
      cron_expression_local: get_param(params, :cron_expression_local),
      user_timezone: timezone,
      scheduled_at: parse_datetime(get_param(params, :scheduled_at)),
      starts_at: parse_datetime(get_param(params, :starts_at)) || DateTime.utc_now(),
      ends_at: parse_datetime(get_param(params, :ends_at))
    }

    attrs = Map.put(attrs, :user_id, ctx.user_id)

    case Magus.Workflows.create_job(ctx.conversation_id, attrs, actor: ai_actor()) do
      {:ok, job} ->
        Logger.info("CreateJob: created", name: job.name, id: job.id)

        {:ok,
         %{
           status: "created",
           job_id: job.id,
           name: job.name,
           schedule_type: job.schedule_type,
           next_run_at: format_datetime(job.next_run_at, timezone)
         }}

      {:error, error} ->
        message = extract_error_message(error)
        Logger.warning("CreateJob: failed - #{message}")
        {:ok, %{error: message}}
    end
  end

  # Convert string schedule_type to atom
  defp parse_schedule_type("cron"), do: :cron
  defp parse_schedule_type("one_time"), do: :one_time
  defp parse_schedule_type(:cron), do: :cron
  defp parse_schedule_type(:one_time), do: :one_time
  defp parse_schedule_type(other), do: other
end
