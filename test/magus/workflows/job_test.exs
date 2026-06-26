defmodule Magus.Workflows.JobTest do
  @moduledoc """
  Tests for the Job resource.

  Tests cover:
  - Job CRUD operations
  - Validations (cron expression, schedule type requirements)
  - Status transitions (pause, resume, stop, complete)
  - Unique name constraint per conversation
  - Authorization policies
  - AshOban trigger configuration
  """
  use Magus.ResourceCase, async: true
  use Oban.Testing, repo: Magus.Repo

  alias Magus.Workflows
  alias Magus.Chat

  describe "Job.create - one-time jobs" do
    test "creates one-time job with valid attributes" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      scheduled_at = DateTime.add(DateTime.utc_now(), 1, :hour)

      {:ok, job} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "Daily Reminder",
            trigger_prompt: "Send a reminder",
            schedule_type: :one_time,
            scheduled_at: scheduled_at,
            starts_at: DateTime.utc_now()
          },
          actor: user,
          authorize?: false
        )

      assert job.name == "Daily Reminder"
      assert job.trigger_prompt == "Send a reminder"
      assert job.schedule_type == :one_time
      assert job.status == :active
      assert job.retry_count == 0
      assert job.max_retries == 3
      assert job.scheduled_at == scheduled_at
    end

    test "calculates next_run_at for one-time job" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      scheduled_at = DateTime.add(DateTime.utc_now(), 2, :hour)

      {:ok, job} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "One Time Task",
            trigger_prompt: "Do something",
            schedule_type: :one_time,
            scheduled_at: scheduled_at,
            starts_at: DateTime.utc_now()
          },
          actor: user,
          authorize?: false
        )

      assert job.next_run_at == scheduled_at
    end

    test "requires scheduled_at for one-time jobs" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:error, error} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "Missing Scheduled",
            trigger_prompt: "Test",
            schedule_type: :one_time,
            starts_at: DateTime.utc_now()
          },
          actor: user,
          authorize?: false
        )

      assert %Ash.Error.Invalid{} = error
    end
  end

  describe "Job.create - cron jobs" do
    test "creates cron job with valid attributes" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, job} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "Daily Report",
            trigger_prompt: "Generate daily report",
            schedule_type: :cron,
            cron_expression: "0 9 * * *",
            starts_at: DateTime.utc_now(),
            ends_at: DateTime.add(DateTime.utc_now(), 30, :day)
          },
          actor: user,
          authorize?: false
        )

      assert job.name == "Daily Report"
      assert job.schedule_type == :cron
      assert job.cron_expression == "0 9 * * *"
      assert job.status == :active
    end

    test "calculates next_run_at for cron job" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, job} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "Hourly Check",
            trigger_prompt: "Check status",
            schedule_type: :cron,
            cron_expression: "0 * * * *",
            starts_at: DateTime.utc_now(),
            ends_at: DateTime.add(DateTime.utc_now(), 30, :day)
          },
          actor: user,
          authorize?: false
        )

      assert job.next_run_at != nil
      # Next run should be in the future
      assert DateTime.compare(job.next_run_at, DateTime.utc_now()) == :gt
    end

    test "requires cron_expression for cron jobs" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:error, error} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "Missing Cron",
            trigger_prompt: "Test",
            schedule_type: :cron,
            starts_at: DateTime.utc_now(),
            ends_at: DateTime.add(DateTime.utc_now(), 30, :day)
          },
          actor: user,
          authorize?: false
        )

      assert %Ash.Error.Invalid{} = error
    end

    test "requires ends_at for cron jobs" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:error, error} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "Missing End",
            trigger_prompt: "Test",
            schedule_type: :cron,
            cron_expression: "0 9 * * *",
            starts_at: DateTime.utc_now()
          },
          actor: user,
          authorize?: false
        )

      assert %Ash.Error.Invalid{} = error
    end

    test "validates cron expression syntax" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:error, error} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "Invalid Cron",
            trigger_prompt: "Test",
            schedule_type: :cron,
            cron_expression: "invalid cron syntax",
            starts_at: DateTime.utc_now(),
            ends_at: DateTime.add(DateTime.utc_now(), 30, :day)
          },
          actor: user,
          authorize?: false
        )

      assert %Ash.Error.Invalid{} = error
    end

    test "accepts standard cron shortcuts" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, job} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "Daily Job",
            trigger_prompt: "Test",
            schedule_type: :cron,
            cron_expression: "@daily",
            starts_at: DateTime.utc_now(),
            ends_at: DateTime.add(DateTime.utc_now(), 30, :day)
          },
          actor: user,
          authorize?: false
        )

      assert job.cron_expression == "@daily"
    end
  end

  describe "Job.update" do
    test "updates job attributes" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      job =
        generate(
          job(
            conversation_id: conversation.id,
            user_id: user.id,
            name: "Original Name"
          )
        )

      {:ok, updated} =
        Workflows.update_job(
          job,
          %{name: "Updated Name", description: "New description"},
          actor: user,
          authorize?: false
        )

      assert updated.name == "Updated Name"
      assert updated.description == "New description"
    end
  end

  describe "Job status transitions" do
    setup do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      job =
        generate(
          job(
            conversation_id: conversation.id,
            user_id: user.id
          )
        )

      %{user: user, conversation: conversation, job: job}
    end

    test "pause sets status to paused", %{job: job} do
      assert job.status == :active

      {:ok, paused} = Workflows.pause_job(job, authorize?: false)

      assert paused.status == :paused
    end

    test "resume sets status to active and recalculates next_run", %{job: job} do
      {:ok, paused} = Workflows.pause_job(job, authorize?: false)
      {:ok, resumed} = Workflows.resume_job(paused, authorize?: false)

      assert resumed.status == :active
      assert resumed.next_run_at != nil
    end

    test "stop sets status to stopped", %{job: job} do
      {:ok, stopped} = Workflows.stop_job(job, authorize?: false)

      assert stopped.status == :stopped
    end

    test "complete sets status to completed", %{job: job} do
      {:ok, completed} = Workflows.complete_job(job, authorize?: false)

      assert completed.status == :completed
    end

    test "mark_run updates last_run_at and resets retry_count", %{job: job} do
      # Increment retry count first
      {:ok, with_retries} = Workflows.increment_job_retry(job, authorize?: false)
      assert with_retries.retry_count == 1

      {:ok, after_run} = Workflows.mark_job_run(with_retries, authorize?: false)

      assert after_run.last_run_at != nil
      assert after_run.retry_count == 0
    end

    test "increment_retry increases retry_count", %{job: job} do
      assert job.retry_count == 0

      {:ok, first} = Workflows.increment_job_retry(job, authorize?: false)
      assert first.retry_count == 1

      {:ok, second} = Workflows.increment_job_retry(first, authorize?: false)
      assert second.retry_count == 2
    end
  end

  describe "Job queries" do
    test "for_conversation returns active jobs for conversation" do
      user = generate(user())
      {:ok, conv1} = Chat.create_conversation(%{}, actor: user)
      {:ok, conv2} = Chat.create_conversation(%{}, actor: user)

      job1 = job(conversation_id: conv1.id, user_id: user.id, name: "Job 1")
      job2 = job(conversation_id: conv1.id, user_id: user.id, name: "Job 2")
      _job3 = job(conversation_id: conv2.id, user_id: user.id, name: "Job 3")

      # Stop one job
      {:ok, _} = Workflows.stop_job(job1, authorize?: false)

      {:ok, jobs} = Workflows.list_jobs_for_conversation(conv1.id, authorize?: false)

      assert length(jobs) == 1
      assert hd(jobs).id == job2.id
    end

    test "for_user returns active jobs for user" do
      user1 = generate(user())
      user2 = generate(user())
      {:ok, conv1} = Chat.create_conversation(%{}, actor: user1)
      {:ok, conv2} = Chat.create_conversation(%{}, actor: user2)

      job1 = job(conversation_id: conv1.id, user_id: user1.id)
      _job2 = job(conversation_id: conv2.id, user_id: user2.id)

      {:ok, jobs} = Workflows.list_jobs_for_user(user1.id, authorize?: false)

      assert length(jobs) == 1
      assert hd(jobs).id == job1.id
    end

    test "due_for_execution returns jobs ready to run" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      # Job due now (scheduled in the past)
      past_time = DateTime.add(DateTime.utc_now(), -1, :hour)

      {:ok, due_job} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "Due Job",
            trigger_prompt: "Test",
            schedule_type: :one_time,
            scheduled_at: past_time,
            starts_at: DateTime.add(DateTime.utc_now(), -2, :hour)
          },
          actor: user,
          authorize?: false
        )

      # Job not yet due
      _future_job =
        generate(
          job(
            conversation_id: conversation.id,
            user_id: user.id,
            name: "Future Job",
            scheduled_at: DateTime.add(DateTime.utc_now(), 1, :hour)
          )
        )

      {:ok, due_jobs} = Workflows.list_due_jobs(authorize?: false)

      # Should find the due job
      due_ids = Enum.map(due_jobs, & &1.id)
      assert due_job.id in due_ids
    end
  end

  describe "unique name constraint" do
    test "prevents duplicate names in same conversation" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      _first = job(conversation_id: conversation.id, user_id: user.id, name: "Unique")

      {:error, error} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "Unique",
            trigger_prompt: "Test",
            schedule_type: :one_time,
            scheduled_at: DateTime.add(DateTime.utc_now(), 1, :hour),
            starts_at: DateTime.utc_now()
          },
          actor: user,
          authorize?: false
        )

      assert %Ash.Error.Unknown{} = error
    end

    test "allows same name in different conversations" do
      user = generate(user())
      {:ok, conv1} = Chat.create_conversation(%{}, actor: user)
      {:ok, conv2} = Chat.create_conversation(%{}, actor: user)

      _first = job(conversation_id: conv1.id, user_id: user.id, name: "Shared")

      second = job(conversation_id: conv2.id, user_id: user.id, name: "Shared")

      assert second.name == "Shared"
    end

    test "allows reusing name after job is stopped" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      first = job(conversation_id: conversation.id, user_id: user.id, name: "Reusable")
      {:ok, _stopped} = Workflows.stop_job(first, authorize?: false)

      second = job(conversation_id: conversation.id, user_id: user.id, name: "Reusable")

      assert second.name == "Reusable"
      assert second.id != first.id
    end
  end

  describe "authorization" do
    test "user can read own jobs" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      job = job(conversation_id: conversation.id, user_id: user.id)

      {:ok, read} = Workflows.get_job(job.id, actor: user)

      assert read.id == job.id
    end

    test "user cannot read other user's jobs" do
      user1 = generate(user())
      user2 = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user1)

      job = job(conversation_id: conversation.id, user_id: user1.id)

      {:error, %Ash.Error.Invalid{}} = Workflows.get_job(job.id, actor: user2)
    end

    test "user can update own jobs" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      job = job(conversation_id: conversation.id, user_id: user.id)

      {:ok, updated} = Workflows.update_job(job, %{description: "Updated"}, actor: user)

      assert updated.description == "Updated"
    end

    test "user cannot update other user's jobs" do
      user1 = generate(user())
      user2 = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user1)

      job = job(conversation_id: conversation.id, user_id: user1.id)

      assert_forbidden(fn ->
        Workflows.update_job(job, %{description: "Hacked"}, actor: user2)
      end)
    end
  end

  describe "optional fields" do
    test "memory_name is optional" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, job} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "No Memory",
            trigger_prompt: "Test",
            schedule_type: :one_time,
            scheduled_at: DateTime.add(DateTime.utc_now(), 1, :hour),
            starts_at: DateTime.utc_now()
          },
          actor: user,
          authorize?: false
        )

      assert job.memory_name == nil
    end

    test "memory_name can be set" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, job} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "With Memory",
            trigger_prompt: "Test",
            schedule_type: :one_time,
            scheduled_at: DateTime.add(DateTime.utc_now(), 1, :hour),
            starts_at: DateTime.utc_now(),
            memory_name: "Study Plan"
          },
          actor: user,
          authorize?: false
        )

      assert job.memory_name == "Study Plan"
    end

    test "user_timezone defaults to UTC" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      job = job(conversation_id: conversation.id, user_id: user.id)

      assert job.user_timezone == "UTC"
    end
  end
end
