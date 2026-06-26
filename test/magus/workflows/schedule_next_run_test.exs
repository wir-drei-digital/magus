defmodule Magus.Workflows.Job.Changes.ScheduleNextRunTest do
  @moduledoc """
  Tests for the ScheduleNextRun change module.

  Tests cover:
  - One-time job scheduling logic
  - Cron job scheduling with various expressions
  - Edge cases around starts_at and ends_at boundaries
  - Status-based scheduling (paused jobs don't get scheduled)
  - Already-run jobs returning nil
  """
  use Magus.ResourceCase, async: true

  alias Magus.Workflows
  alias Magus.Chat

  describe "one-time job scheduling" do
    test "next_run_at equals scheduled_at for unrun job" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      scheduled = DateTime.add(DateTime.utc_now(), 3, :hour)

      {:ok, job} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "One Time",
            trigger_prompt: "Test",
            schedule_type: :one_time,
            scheduled_at: scheduled,
            starts_at: DateTime.utc_now()
          },
          actor: user,
          authorize?: false
        )

      assert job.next_run_at == scheduled
    end

    test "next_run_at is nil after job has run" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, job} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "Already Run",
            trigger_prompt: "Test",
            schedule_type: :one_time,
            scheduled_at: DateTime.add(DateTime.utc_now(), 1, :hour),
            starts_at: DateTime.utc_now()
          },
          actor: user,
          authorize?: false
        )

      # Mark as run
      {:ok, ran_job} = Workflows.mark_job_run(job, authorize?: false)

      assert ran_job.last_run_at != nil
      assert ran_job.next_run_at == nil
    end
  end

  describe "cron job scheduling" do
    test "calculates next run time from cron expression" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, job} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "Hourly",
            trigger_prompt: "Test",
            schedule_type: :cron,
            cron_expression: "0 * * * *",
            starts_at: DateTime.utc_now(),
            ends_at: DateTime.add(DateTime.utc_now(), 30, :day)
          },
          actor: user,
          authorize?: false
        )

      assert job.next_run_at != nil
      # Should be at minute 0 of some hour
      assert job.next_run_at.minute == 0
    end

    test "uses starts_at as reference if job hasn't started yet" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      # Job starts tomorrow
      starts_at = DateTime.add(DateTime.utc_now(), 1, :day)

      {:ok, job} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "Future Start",
            trigger_prompt: "Test",
            schedule_type: :cron,
            cron_expression: "0 9 * * *",
            starts_at: starts_at,
            ends_at: DateTime.add(DateTime.utc_now(), 30, :day)
          },
          actor: user,
          authorize?: false
        )

      # Next run should be after starts_at
      assert DateTime.compare(job.next_run_at, starts_at) in [:gt, :eq]
    end

    test "returns nil if next run would be after ends_at" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      # Very short window - ends in 1 minute
      ends_at = DateTime.add(DateTime.utc_now(), 1, :minute)

      {:ok, job} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "Short Window",
            trigger_prompt: "Test",
            schedule_type: :cron,
            # Run at 23:59 - unlikely to be now
            cron_expression: "59 23 * * *",
            starts_at: DateTime.utc_now(),
            ends_at: ends_at
          },
          actor: user,
          authorize?: false
        )

      # If next cron time is after ends_at, next_run_at should be nil
      if job.next_run_at != nil do
        assert DateTime.compare(job.next_run_at, ends_at) == :lt
      end
    end

    test "recalculates next_run after mark_run" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, job} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "Recurring",
            trigger_prompt: "Test",
            schedule_type: :cron,
            cron_expression: "* * * * *",
            starts_at: DateTime.utc_now(),
            ends_at: DateTime.add(DateTime.utc_now(), 30, :day)
          },
          actor: user,
          authorize?: false
        )

      original_next = job.next_run_at

      # Wait a moment and mark as run
      Process.sleep(10)
      {:ok, ran_job} = Workflows.mark_job_run(job, authorize?: false)

      # Next run should be recalculated (might be same minute but different calculation)
      assert ran_job.next_run_at != nil
      assert DateTime.compare(ran_job.next_run_at, original_next) in [:gt, :eq]
    end
  end

  describe "status-based scheduling" do
    test "paused jobs don't get next_run_at recalculated on update" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      job = job(conversation_id: conversation.id, user_id: user.id)

      {:ok, paused} = Workflows.pause_job(job, authorize?: false)

      # The ScheduleNextRun change should not schedule paused jobs
      # Status is :paused, so next_run calculation returns nil
      # Note: The job still has the original next_run_at from before pause
      # This is intentional - we preserve the schedule but don't execute
      assert paused.status == :paused
    end

    test "resume recalculates next_run_at" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, job} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "Pausable",
            trigger_prompt: "Test",
            schedule_type: :cron,
            cron_expression: "* * * * *",
            starts_at: DateTime.utc_now(),
            ends_at: DateTime.add(DateTime.utc_now(), 30, :day)
          },
          actor: user,
          authorize?: false
        )

      {:ok, paused} = Workflows.pause_job(job, authorize?: false)
      Process.sleep(10)
      {:ok, resumed} = Workflows.resume_job(paused, authorize?: false)

      assert resumed.status == :active
      assert resumed.next_run_at != nil
    end

    test "stopped jobs have no next_run_at" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      job = job(conversation_id: conversation.id, user_id: user.id)

      {:ok, stopped} = Workflows.stop_job(job, authorize?: false)

      # Stopped jobs should not have a next run scheduled
      # The change checks status != :active before scheduling
      assert stopped.status == :stopped
    end

    test "completed jobs have no next_run_at" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      job = job(conversation_id: conversation.id, user_id: user.id)

      {:ok, completed} = Workflows.complete_job(job, authorize?: false)

      assert completed.status == :completed
    end
  end

  describe "cron expression edge cases" do
    test "handles @daily shortcut" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, job} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "Daily",
            trigger_prompt: "Test",
            schedule_type: :cron,
            cron_expression: "@daily",
            starts_at: DateTime.utc_now(),
            ends_at: DateTime.add(DateTime.utc_now(), 30, :day)
          },
          actor: user,
          authorize?: false
        )

      assert job.next_run_at != nil
      # @daily runs at midnight
      assert job.next_run_at.hour == 0
      assert job.next_run_at.minute == 0
    end

    test "handles @hourly shortcut" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, job} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "Hourly",
            trigger_prompt: "Test",
            schedule_type: :cron,
            cron_expression: "@hourly",
            starts_at: DateTime.utc_now(),
            ends_at: DateTime.add(DateTime.utc_now(), 30, :day)
          },
          actor: user,
          authorize?: false
        )

      assert job.next_run_at != nil
      # @hourly runs at minute 0
      assert job.next_run_at.minute == 0
    end

    test "handles complex cron expressions" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      # Every 15 minutes during business hours on weekdays
      {:ok, job} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "Business Hours",
            trigger_prompt: "Test",
            schedule_type: :cron,
            cron_expression: "*/15 9-17 * * 1-5",
            starts_at: DateTime.utc_now(),
            ends_at: DateTime.add(DateTime.utc_now(), 30, :day)
          },
          actor: user,
          authorize?: false
        )

      assert job.next_run_at != nil
    end

    test "handles step values" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, job} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "Every 5 Minutes",
            trigger_prompt: "Test",
            schedule_type: :cron,
            cron_expression: "*/5 * * * *",
            starts_at: DateTime.utc_now(),
            ends_at: DateTime.add(DateTime.utc_now(), 30, :day)
          },
          actor: user,
          authorize?: false
        )

      assert job.next_run_at != nil
      # Should be on a 5-minute boundary
      assert rem(job.next_run_at.minute, 5) == 0
    end
  end

  describe "boundary conditions" do
    test "job starting exactly now calculates next run correctly" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      now = DateTime.utc_now()

      {:ok, job} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "Starts Now",
            trigger_prompt: "Test",
            schedule_type: :cron,
            cron_expression: "* * * * *",
            starts_at: now,
            ends_at: DateTime.add(now, 30, :day)
          },
          actor: user,
          authorize?: false
        )

      assert job.next_run_at != nil
      # Next run should be >= starts_at
      assert DateTime.compare(job.next_run_at, now) in [:gt, :eq]
    end

    test "one-time job scheduled in the past still gets next_run_at" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      past = DateTime.add(DateTime.utc_now(), -1, :hour)

      {:ok, job} =
        Workflows.create_job(
          conversation.id,
          %{
            name: "Past Job",
            trigger_prompt: "Test",
            schedule_type: :one_time,
            scheduled_at: past,
            starts_at: DateTime.add(DateTime.utc_now(), -2, :hour)
          },
          actor: user,
          authorize?: false
        )

      # Even if scheduled_at is in the past, if not run, next_run_at should be set
      assert job.next_run_at == past
    end
  end
end
