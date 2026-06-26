defmodule Magus.Workflows do
  @moduledoc """
  Domain for scheduled workflow jobs.

  Workflows allow AI agents to schedule recurring tasks, send emails,
  and maintain persistent execution history. Jobs can be scheduled via
  cron expressions or as one-time executions.

  ## Job Functions

  - `create_job/2` - Create a new job (requires actor for user association)
  - `update_job/2` - Update job attributes
  - `pause_job/2` - Pause a running job
  - `resume_job/2` - Resume a paused job
  - `stop_job/2` - Permanently stop a job
  - `complete_job/2` - Mark a job as completed
  - `mark_job_run/2` - Mark a job as having run (updates timestamps)
  - `increment_job_retry/2` - Increment retry count
  - `get_job/2` - Get a job by ID
  - `list_jobs_for_conversation/2` - List active jobs for a conversation
  - `list_jobs_for_user/2` - List active jobs for a user
  - `list_due_jobs/1` - List jobs due for execution
  - `trigger_job_now/2` - Manually trigger a job execution

  ## JobRun Functions

  - `create_job_run/2` - Create a run record for a job
  - `start_job_run/2` - Mark a run as started
  - `succeed_job_run/3` - Mark a run as successful
  - `fail_job_run/3` - Mark a run as failed
  - `retry_job_run/2` - Mark a run for retry
  - `set_job_run_trigger_message/3` - Link trigger message to run
  - `list_runs_for_job/2` - List all runs for a job
  - `list_recent_runs_for_job/2` - List recent runs for a job

  ## NotificationPreference Functions

  - `create_notification_preference/2` - Create preferences for a job
  - `update_notification_preference/2` - Update notification preferences
  """

  use Ash.Domain, otp_app: :magus, extensions: [AshTypescript.Rpc]

  typescript_rpc do
    # Right-rail jobs panel: list + lifecycle controls. Job creation stays
    # AI-tool-only (classic has no manual create in the rail either).
    resource Magus.Workflows.Job do
      rpc_action :conversation_jobs, :for_conversation
      rpc_action :user_jobs, :for_user
      rpc_action :pause_job, :pause
      rpc_action :resume_job, :resume
      rpc_action :stop_job, :stop
      rpc_action :trigger_job_now, :execute
    end

    resource Magus.Workflows.JobRun do
      rpc_action :job_runs, :recent_for_job
    end
  end

  resources do
    resource Magus.Workflows.Job do
      define :create_job, action: :create, args: [:conversation_id]
      define :update_job, action: :update
      define :pause_job, action: :pause
      define :resume_job, action: :resume
      define :stop_job, action: :stop
      define :complete_job, action: :complete
      define :mark_job_run, action: :mark_run
      define :increment_job_retry, action: :increment_retry
      define :get_job, action: :read, get_by: [:id]
      define :list_jobs_for_conversation, action: :for_conversation, args: [:conversation_id]

      define :list_all_jobs_for_conversation,
        action: :all_for_conversation,
        args: [:conversation_id]

      define :list_jobs_for_user, action: :for_user, args: [:user_id]
      define :list_due_jobs, action: :due_for_execution
    end

    resource Magus.Workflows.JobRun do
      define :create_job_run, action: :create, args: [:job_id]
      define :start_job_run, action: :start
      define :succeed_job_run, action: :succeed, args: [:response_message_id]
      define :fail_job_run, action: :fail, args: [:error_message]
      define :retry_job_run, action: :retry

      define :set_job_run_trigger_message,
        action: :set_trigger_message,
        args: [:trigger_message_id]

      define :list_runs_for_job, action: :for_job, args: [:job_id]
      define :list_recent_runs_for_job, action: :recent_for_job, args: [:job_id]
    end

    resource Magus.Workflows.NotificationPreference do
      define :create_notification_preference, action: :create, args: [:job_id]
      define :update_notification_preference, action: :update
    end
  end

  @doc """
  Manually trigger a job execution now.

  This queues the job's execute action to run via AshOban, which will
  create a JobRun, trigger message, and AI response.

  ## Options

    - `:actor` - Required. The user triggering the job.

  ## Examples

      {:ok, job} = Workflows.trigger_job_now(job, actor: user)

  """
  def trigger_job_now(job, opts \\ []) do
    actor = Keyword.fetch!(opts, :actor)

    # Call the :execute action directly, bypassing the AshOban scheduler
    # and its `where` clause. This allows manual triggering regardless of
    # the job's due_for_execution status.
    job
    |> Ash.Changeset.for_update(:execute, %{}, actor: actor)
    |> Ash.update()
  end
end
