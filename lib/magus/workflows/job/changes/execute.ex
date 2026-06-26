defmodule Magus.Workflows.Job.Changes.Execute do
  @moduledoc """
  Handles job execution: creates trigger message, waits for agent response.

  When a job is executed:
  1. Creates a JobRun to track execution
  2. Loads relevant memory (specific or most recent)
  3. Creates a trigger message in the conversation
  4. The trigger message triggers the AI agent to respond

  Note: This implementation creates an event message with job context.
  A future enhancement could add a dedicated job_trigger message type
  to the Message resource for better tracking and UI differentiation.
  """

  use Ash.Resource.Change

  require Logger

  # Use AiAgent actor for audit trail instead of authorize?: false
  @ai_agent %Magus.Agents.Support.AiAgent{}

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, job ->
      execute_job(job)
    end)
  end

  defp execute_job(job) do
    # 1. Create JobRun
    case Magus.Workflows.create_job_run(job.id, actor: @ai_agent) do
      {:ok, job_run} ->
        try do
          do_execute_job(job, job_run)
        rescue
          e ->
            Logger.error("Job execution failed: #{inspect(e)}")
            handle_failure(job, job_run, Exception.message(e))
        end

      {:error, error} ->
        Logger.error("Failed to create job run: #{inspect(error)}")
        {:error, error}
    end
  end

  defp do_execute_job(job, job_run) do
    # 2. Load memory (specific or most recent)
    memory = load_memory(job)

    # 3. Create trigger message in conversation
    trigger_content = build_trigger_content(job, memory)

    with {:ok, trigger_message} <- create_trigger_message(job, trigger_content, memory),
         # 4. Link trigger message to job run
         {:ok, job_run} <-
           Magus.Workflows.set_job_run_trigger_message(job_run, trigger_message.id,
             actor: @ai_agent
           ),
         # 5. Mark job run as running
         {:ok, job_run} <- Magus.Workflows.start_job_run(job_run, actor: @ai_agent),
         # 6. Mark job run as succeeded (trigger message was created successfully)
         # Note: The actual AI response happens asynchronously via the message pipeline
         {:ok, _job_run} <-
           Magus.Workflows.succeed_job_run(job_run, trigger_message.id, actor: @ai_agent) do
      # 7. Update job and return the updated job
      Magus.Workflows.mark_job_run(job, actor: @ai_agent)
    else
      {:error, error} ->
        Logger.error("Job execution failed: #{inspect(error)}")
        handle_failure(job, job_run, "Job execution failed: #{inspect(error)}")
    end
  end

  defp load_memory(job) do
    if job.memory_name do
      case Magus.Memory.get_memory_by_name(job.conversation_id, job.memory_name, actor: @ai_agent) do
        {:ok, memory} -> memory
        _ -> get_most_recent_memory(job.conversation_id)
      end
    else
      get_most_recent_memory(job.conversation_id)
    end
  end

  defp get_most_recent_memory(conversation_id) do
    case Magus.Memory.get_most_recent_memory(conversation_id, actor: @ai_agent) do
      {:ok, memory} -> memory
      _ -> nil
    end
  end

  defp build_trigger_content(job, memory) do
    memory_context =
      if memory do
        """

        [Memory: #{memory.name}]
        #{memory.summary}
        """
      else
        ""
      end

    """
    [Scheduled Job: #{job.name}]
    #{job.trigger_prompt}#{memory_context}
    """
  end

  defp create_trigger_message(job, content, memory) do
    # Create a job trigger message that will automatically trigger the AI agent
    # to respond via the Oban job queue
    memory_name = if(memory, do: memory.name, else: job.memory_name)

    Magus.Chat.create_job_trigger_message(
      content,
      job.conversation_id,
      job.id,
      job.name,
      memory_name,
      actor: @ai_agent
    )
  end

  defp handle_failure(job, job_run, error_message) do
    # Mark run as failed
    Magus.Workflows.fail_job_run(job_run, error_message, actor: @ai_agent)

    # Reload job to get fresh retry_count (avoid race condition with concurrent executions)
    # Handle case where job was deleted during execution
    case Magus.Workflows.get_job(job.id, actor: @ai_agent) do
      {:ok, fresh_job} ->
        # Check retry logic using fresh data
        if fresh_job.retry_count < fresh_job.max_retries do
          Magus.Workflows.increment_job_retry(fresh_job, actor: @ai_agent)
          # Oban will handle retry scheduling
          {:ok, fresh_job}
        else
          # Max retries exceeded
          notify_failure(fresh_job, error_message)
          # Continue to next scheduled run
          Magus.Workflows.mark_job_run(fresh_job, actor: @ai_agent)
        end

      {:error, %Ash.Error.Query.NotFound{}} ->
        # Job was deleted during execution - nothing more to do
        Logger.warning("Job #{job.id} was deleted during execution")
        {:ok, job}

      {:error, error} ->
        Logger.error("Failed to reload job #{job.id}: #{inspect(error)}")
        {:error, error}
    end
  end

  defp notify_failure(job, error_message) do
    # Create error message in conversation
    Magus.Chat.Message
    |> Ash.Changeset.for_create(:create_event, %{
      text: "[Job Failed: #{job.name}]\n#{error_message}",
      conversation_id: job.conversation_id
    })
    |> Ash.Changeset.force_change_attribute(:metadata, %{
      job_id: job.id,
      error: true
    })
    |> Ash.create(actor: @ai_agent)

    # Check notification preferences
    job = Ash.load!(job, :notification_preference, actor: @ai_agent)

    case job.notification_preference do
      %{notify_on_failure: true, notification_channels: channels} ->
        if :email in channels do
          send_failure_email(job, error_message)
        end

      _ ->
        :ok
    end
  end

  defp send_failure_email(job, error_message) do
    job = Ash.load!(job, :user, actor: @ai_agent)
    email = Magus.Emails.JobFailure.build(job.user, job, error_message)

    case Magus.Mailer.deliver(email) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to send job-failure email to #{job.user.email} " <>
            "for job #{job.name}: #{inspect(reason)}"
        )
    end
  end
end
