defmodule Magus.Agents.Tools.Jobs.JobToolsTest do
  @moduledoc """
  Comprehensive tests for all job tools.

  Tests cover:
  - Tool execution with valid context
  - Tool execution with missing context
  - Error handling
  - Integration with the Workflows domain
  - Display name and output summarization
  - Job lifecycle (create, pause, resume, stop)
  """
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Jobs.{
    CreateJob,
    UpdateJob,
    ListJobs,
    StopJob,
    PauseJob,
    ResumeJob
  }

  alias Magus.Chat

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  defp create_test_context do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

    %{
      user: user,
      conversation: conversation,
      context: %{
        user_id: user.id,
        conversation_id: conversation.id,
        folder_id: nil
      }
    }
  end

  defp one_hour_from_now do
    DateTime.utc_now()
    |> DateTime.add(3600, :second)
    |> DateTime.to_iso8601()
  end

  defp one_day_from_now do
    DateTime.utc_now()
    |> DateTime.add(86400, :second)
    |> DateTime.to_iso8601()
  end

  defp one_week_from_now do
    DateTime.utc_now()
    |> DateTime.add(604_800, :second)
    |> DateTime.to_iso8601()
  end

  # ---------------------------------------------------------------------------
  # CreateJob Tests
  # ---------------------------------------------------------------------------

  describe "CreateJob" do
    test "provides display_name" do
      assert CreateJob.display_name() == "Creating job..."
    end

    test "summarizes output correctly" do
      assert CreateJob.summarize_output(%{status: "created", name: "Test"}) == "Created: Test"
      assert CreateJob.summarize_output(%{error: "some error"}) == "Error"
      assert CreateJob.summarize_output(%{}) == "Completed"
    end

    test "creates one-time job with valid context" do
      %{context: context} = create_test_context()

      params = %{
        name: "Test Reminder",
        description: "A test reminder job",
        trigger_prompt: "Send a reminder to the user",
        schedule_type: "one_time",
        scheduled_at: one_hour_from_now()
      }

      assert {:ok, result} = CreateJob.run(params, context)
      assert result.status == "created"
      assert result.name == "Test Reminder"
      assert result.schedule_type == :one_time
      assert result.job_id != nil
    end

    test "creates cron job with valid context" do
      %{context: context} = create_test_context()

      params = %{
        name: "Daily Report",
        trigger_prompt: "Generate daily report",
        schedule_type: "cron",
        cron_expression: "0 9 * * *",
        cron_expression_local: "0 9 * * *",
        ends_at: one_week_from_now()
      }

      assert {:ok, result} = CreateJob.run(params, context)
      assert result.status == "created"
      assert result.name == "Daily Report"
      assert result.schedule_type == :cron
    end

    test "creates job with memory association" do
      %{context: context} = create_test_context()

      params = %{
        name: "Study Reminder",
        trigger_prompt: "Review study plan",
        memory_name: "Study Plan",
        schedule_type: "one_time",
        scheduled_at: one_hour_from_now()
      }

      assert {:ok, result} = CreateJob.run(params, context)
      assert result.status == "created"
    end

    test "returns error with missing context" do
      params = %{
        name: "Test",
        trigger_prompt: "Test",
        schedule_type: "one_time",
        scheduled_at: one_hour_from_now()
      }

      assert {:ok, result} = CreateJob.run(params, %{})
      assert result.error =~ "Missing required context"
    end

    test "returns error with missing conversation_id" do
      params = %{
        name: "Test",
        trigger_prompt: "Test",
        schedule_type: "one_time",
        scheduled_at: one_hour_from_now()
      }

      context = %{user_id: Ash.UUIDv7.generate()}

      assert {:ok, result} = CreateJob.run(params, context)
      assert result.error =~ "Missing required context"
    end

    test "returns error for cron job without ends_at" do
      %{context: context} = create_test_context()

      params = %{
        name: "Forever Job",
        trigger_prompt: "Run forever",
        schedule_type: "cron",
        cron_expression: "0 9 * * *"
      }

      assert {:ok, result} = CreateJob.run(params, context)
      assert result.error != nil
      assert result.error =~ "ends_at" or result.error =~ "required"
    end

    test "returns error for one-time job without scheduled_at" do
      %{context: context} = create_test_context()

      params = %{
        name: "No Time",
        trigger_prompt: "When?",
        schedule_type: "one_time"
      }

      assert {:ok, result} = CreateJob.run(params, context)
      assert result.error != nil
    end

    test "returns error for duplicate job name" do
      %{context: context} = create_test_context()

      params = %{
        name: "Duplicate",
        trigger_prompt: "Test",
        schedule_type: "one_time",
        scheduled_at: one_hour_from_now()
      }

      assert {:ok, %{status: "created"}} = CreateJob.run(params, context)
      assert {:ok, result} = CreateJob.run(params, context)
      assert result.error != nil
    end

    test "returns error for ends_at in the past" do
      %{context: context} = create_test_context()

      past_date =
        DateTime.utc_now()
        |> DateTime.add(-86400, :second)
        |> DateTime.to_iso8601()

      params = %{
        name: "Past End Job",
        trigger_prompt: "Should fail",
        schedule_type: "cron",
        cron_expression: "0 9 * * *",
        ends_at: past_date
      }

      assert {:ok, result} = CreateJob.run(params, context)
      assert result.error != nil
      assert result.error =~ "future"
    end

    test "returns error for ends_at before starts_at" do
      %{context: context} = create_test_context()

      # starts_at is 1 week from now, ends_at is 1 day from now
      starts_at =
        DateTime.utc_now()
        |> DateTime.add(7 * 86400, :second)
        |> DateTime.to_iso8601()

      ends_at =
        DateTime.utc_now()
        |> DateTime.add(86400, :second)
        |> DateTime.to_iso8601()

      params = %{
        name: "Invalid Range Job",
        trigger_prompt: "Should fail",
        schedule_type: "cron",
        cron_expression: "0 9 * * *",
        starts_at: starts_at,
        ends_at: ends_at
      }

      assert {:ok, result} = CreateJob.run(params, context)
      assert result.error != nil
      assert result.error =~ "after"
    end
  end

  # ---------------------------------------------------------------------------
  # UpdateJob Tests
  # ---------------------------------------------------------------------------

  describe "UpdateJob" do
    test "provides display_name" do
      assert UpdateJob.display_name() == "Updating job..."
    end

    test "summarizes output correctly" do
      assert UpdateJob.summarize_output(%{status: "updated", name: "Test"}) == "Updated: Test"
      assert UpdateJob.summarize_output(%{error: "some error"}) == "Error"
      assert UpdateJob.summarize_output(%{}) == "Completed"
    end

    test "updates job description" do
      %{context: context} = create_test_context()

      # Create a job first
      CreateJob.run(
        %{
          name: "Update Me",
          trigger_prompt: "Original prompt",
          schedule_type: "one_time",
          scheduled_at: one_hour_from_now()
        },
        context
      )

      # Update it
      params = %{
        name: "Update Me",
        description: "New description"
      }

      assert {:ok, result} = UpdateJob.run(params, context)
      assert result.status == "updated"
      assert result.name == "Update Me"
    end

    test "updates job trigger_prompt" do
      %{context: context} = create_test_context()

      CreateJob.run(
        %{
          name: "Prompt Job",
          trigger_prompt: "Original",
          schedule_type: "one_time",
          scheduled_at: one_hour_from_now()
        },
        context
      )

      params = %{
        name: "Prompt Job",
        trigger_prompt: "Updated prompt"
      }

      assert {:ok, result} = UpdateJob.run(params, context)
      assert result.status == "updated"
    end

    test "renames job" do
      %{context: context} = create_test_context()

      CreateJob.run(
        %{
          name: "Old Name",
          trigger_prompt: "Test",
          schedule_type: "one_time",
          scheduled_at: one_hour_from_now()
        },
        context
      )

      params = %{
        name: "Old Name",
        new_name: "New Name"
      }

      assert {:ok, result} = UpdateJob.run(params, context)
      assert result.status == "updated"
      assert result.name == "New Name"
    end

    test "updating cron_expression recalculates next_run_at" do
      %{context: context} = create_test_context()

      # Create a cron job
      CreateJob.run(
        %{
          name: "Cron Job",
          trigger_prompt: "Test",
          schedule_type: "cron",
          cron_expression: "0 9 * * *",
          ends_at: one_week_from_now()
        },
        context
      )

      # Get original next_run_at
      {:ok, %{jobs: [original_job]}} = ListJobs.run(%{}, context)
      assert original_job.next_run_at != nil

      # Update to a different cron expression (every hour instead of daily)
      {:ok, result} = UpdateJob.run(%{name: "Cron Job", cron_expression: "0 * * * *"}, context)

      assert result.status == "updated"
      # next_run_at should be recalculated and present
      assert result.next_run_at != nil
    end

    test "returns error for non-existent job" do
      %{context: context} = create_test_context()

      params = %{
        name: "Non-existent",
        description: "Update non-existent"
      }

      assert {:ok, result} = UpdateJob.run(params, context)
      assert result.error =~ "not found"
    end

    test "returns error with missing context" do
      params = %{name: "Test", description: "Test"}

      assert {:ok, result} = UpdateJob.run(params, %{})
      assert result.error =~ "Missing required context"
    end

    test "returns error when updating ends_at to the past" do
      %{context: context} = create_test_context()

      # Create a valid job first
      CreateJob.run(
        %{
          name: "Update Test Job",
          trigger_prompt: "Test",
          schedule_type: "cron",
          cron_expression: "0 9 * * *",
          ends_at: one_week_from_now()
        },
        context
      )

      past_date =
        DateTime.utc_now()
        |> DateTime.add(-86400, :second)
        |> DateTime.to_iso8601()

      assert {:ok, result} =
               UpdateJob.run(%{name: "Update Test Job", ends_at: past_date}, context)

      assert result.error != nil
      assert result.error =~ "future"
    end

    test "returns error when updating ends_at to before starts_at" do
      %{context: context} = create_test_context()

      starts_at =
        DateTime.utc_now()
        |> DateTime.add(7 * 86400, :second)
        |> DateTime.to_iso8601()

      ends_at =
        DateTime.utc_now()
        |> DateTime.add(14 * 86400, :second)
        |> DateTime.to_iso8601()

      # Create a job with starts_at in the future
      CreateJob.run(
        %{
          name: "Range Test Job",
          trigger_prompt: "Test",
          schedule_type: "cron",
          cron_expression: "0 9 * * *",
          starts_at: starts_at,
          ends_at: ends_at
        },
        context
      )

      # Try to update ends_at to before starts_at
      invalid_ends_at =
        DateTime.utc_now()
        |> DateTime.add(3 * 86400, :second)
        |> DateTime.to_iso8601()

      assert {:ok, result} =
               UpdateJob.run(%{name: "Range Test Job", ends_at: invalid_ends_at}, context)

      assert result.error != nil
      assert result.error =~ "after"
    end

    test "updating starts_at recalculates next_run_at" do
      %{context: context} = create_test_context()

      # Create a job
      {:ok, %{status: "created"}} =
        CreateJob.run(
          %{
            name: "Starts At Test",
            trigger_prompt: "Test",
            schedule_type: "cron",
            cron_expression: "0 9 * * *",
            ends_at: one_week_from_now()
          },
          context
        )

      # Update starts_at
      future_start =
        DateTime.utc_now()
        |> DateTime.add(2 * 86400, :second)
        |> DateTime.to_iso8601()

      {:ok, result} = UpdateJob.run(%{name: "Starts At Test", starts_at: future_start}, context)

      assert result.status == "updated"
      assert result.next_run_at != nil
    end
  end

  # ---------------------------------------------------------------------------
  # ListJobs Tests
  # ---------------------------------------------------------------------------

  describe "ListJobs" do
    test "provides display_name" do
      assert ListJobs.display_name() == "Listing jobs..."
    end

    test "summarizes output correctly" do
      assert ListJobs.summarize_output(%{count: 0}) == "No jobs found"
      assert ListJobs.summarize_output(%{count: 5}) == "Found 5 jobs"
      assert ListJobs.summarize_output(%{error: "some error"}) == "Error"
    end

    test "returns empty list for new conversation" do
      %{context: context} = create_test_context()

      assert {:ok, result} = ListJobs.run(%{}, context)
      assert result.count == 0
      assert result.jobs == []
    end

    test "lists all active jobs in conversation" do
      %{context: context} = create_test_context()

      # Create some jobs
      CreateJob.run(
        %{
          name: "Job 1",
          trigger_prompt: "P1",
          schedule_type: "one_time",
          scheduled_at: one_hour_from_now()
        },
        context
      )

      CreateJob.run(
        %{
          name: "Job 2",
          trigger_prompt: "P2",
          schedule_type: "one_time",
          scheduled_at: one_day_from_now()
        },
        context
      )

      assert {:ok, result} = ListJobs.run(%{}, context)
      assert result.count == 2
      assert length(result.jobs) == 2

      names = Enum.map(result.jobs, & &1.name)
      assert "Job 1" in names
      assert "Job 2" in names
    end

    test "returns job details" do
      %{context: context} = create_test_context()

      CreateJob.run(
        %{
          name: "Detailed Job",
          description: "A detailed job",
          trigger_prompt: "Prompt",
          memory_name: "MyMemory",
          schedule_type: "one_time",
          scheduled_at: one_hour_from_now()
        },
        context
      )

      assert {:ok, result} = ListJobs.run(%{}, context)
      job = hd(result.jobs)

      assert job.name == "Detailed Job"
      assert job.description == "A detailed job"
      assert job.status == :active
      assert job.schedule_type == :one_time
      assert job.memory_name == "MyMemory"
      assert job.schedule != nil
    end

    test "returns error with missing context" do
      assert {:ok, result} = ListJobs.run(%{}, %{})
      assert result.error =~ "Missing required context"
    end
  end

  # ---------------------------------------------------------------------------
  # StopJob Tests
  # ---------------------------------------------------------------------------

  describe "StopJob" do
    test "provides display_name" do
      assert StopJob.display_name() == "Stopping job..."
    end

    test "summarizes output correctly" do
      assert StopJob.summarize_output(%{status: "stopped", name: "Test"}) == "Stopped: Test"
      assert StopJob.summarize_output(%{error: "some error"}) == "Error"
      assert StopJob.summarize_output(%{}) == "Completed"
    end

    test "stops an active job" do
      %{context: context} = create_test_context()

      CreateJob.run(
        %{
          name: "Stop Me",
          trigger_prompt: "P",
          schedule_type: "one_time",
          scheduled_at: one_hour_from_now()
        },
        context
      )

      assert {:ok, result} = StopJob.run(%{name: "Stop Me"}, context)
      assert result.status == "stopped"
      assert result.name == "Stop Me"
      assert result.message =~ "stopped"
    end

    test "stops a paused job" do
      %{context: context} = create_test_context()

      CreateJob.run(
        %{
          name: "Paused Stop",
          trigger_prompt: "P",
          schedule_type: "one_time",
          scheduled_at: one_hour_from_now()
        },
        context
      )

      # Pause first
      PauseJob.run(%{name: "Paused Stop"}, context)

      # Then stop
      assert {:ok, result} = StopJob.run(%{name: "Paused Stop"}, context)
      assert result.status == "stopped"
    end

    test "returns error for non-existent job" do
      %{context: context} = create_test_context()

      assert {:ok, result} = StopJob.run(%{name: "Non-existent"}, context)
      assert result.error =~ "not found"
    end

    test "returns error with missing context" do
      assert {:ok, result} = StopJob.run(%{name: "Test"}, %{})
      assert result.error =~ "Missing required context"
    end

    test "stopped job no longer appears in list" do
      %{context: context} = create_test_context()

      CreateJob.run(
        %{
          name: "Vanish",
          trigger_prompt: "P",
          schedule_type: "one_time",
          scheduled_at: one_hour_from_now()
        },
        context
      )

      # Verify it's in the list
      {:ok, before} = ListJobs.run(%{}, context)
      assert before.count == 1

      # Stop it
      StopJob.run(%{name: "Vanish"}, context)

      # Verify it's gone (by default)
      {:ok, after_stop} = ListJobs.run(%{}, context)
      assert after_stop.count == 0
    end

    test "stopped job appears when include_stopped is true" do
      %{context: context} = create_test_context()

      CreateJob.run(
        %{
          name: "Stopped Job",
          trigger_prompt: "P",
          schedule_type: "one_time",
          scheduled_at: one_hour_from_now()
        },
        context
      )

      # Stop the job
      StopJob.run(%{name: "Stopped Job"}, context)

      # Verify it's gone by default
      {:ok, without_stopped} = ListJobs.run(%{}, context)
      assert without_stopped.count == 0

      # Verify it appears with include_stopped: true
      {:ok, with_stopped} = ListJobs.run(%{include_stopped: true}, context)
      assert with_stopped.count == 1
      assert hd(with_stopped.jobs).name == "Stopped Job"
      assert hd(with_stopped.jobs).status == :stopped
    end
  end

  # ---------------------------------------------------------------------------
  # PauseJob Tests
  # ---------------------------------------------------------------------------

  describe "PauseJob" do
    test "provides display_name" do
      assert PauseJob.display_name() == "Pausing job..."
    end

    test "summarizes output correctly" do
      assert PauseJob.summarize_output(%{status: "paused", name: "Test"}) == "Paused: Test"
      assert PauseJob.summarize_output(%{error: "some error"}) == "Error"
      assert PauseJob.summarize_output(%{}) == "Completed"
    end

    test "pauses an active job" do
      %{context: context} = create_test_context()

      CreateJob.run(
        %{
          name: "Pause Me",
          trigger_prompt: "P",
          schedule_type: "one_time",
          scheduled_at: one_hour_from_now()
        },
        context
      )

      assert {:ok, result} = PauseJob.run(%{name: "Pause Me"}, context)
      assert result.status == "paused"
      assert result.name == "Pause Me"
      assert result.message =~ "paused"
    end

    test "returns error for already paused job" do
      %{context: context} = create_test_context()

      CreateJob.run(
        %{
          name: "Double Pause",
          trigger_prompt: "P",
          schedule_type: "one_time",
          scheduled_at: one_hour_from_now()
        },
        context
      )

      # Pause once
      PauseJob.run(%{name: "Double Pause"}, context)

      # Try to pause again
      assert {:ok, result} = PauseJob.run(%{name: "Double Pause"}, context)
      assert result.error =~ "already paused"
    end

    test "returns error for stopped job" do
      %{context: context} = create_test_context()

      CreateJob.run(
        %{
          name: "Stopped Job",
          trigger_prompt: "P",
          schedule_type: "one_time",
          scheduled_at: one_hour_from_now()
        },
        context
      )

      StopJob.run(%{name: "Stopped Job"}, context)

      assert {:ok, result} = PauseJob.run(%{name: "Stopped Job"}, context)
      # Job not found because stopped jobs are filtered out
      assert result.error =~ "not found" or result.error =~ "stopped"
    end

    test "returns error for non-existent job" do
      %{context: context} = create_test_context()

      assert {:ok, result} = PauseJob.run(%{name: "Non-existent"}, context)
      assert result.error =~ "not found"
    end

    test "returns error with missing context" do
      assert {:ok, result} = PauseJob.run(%{name: "Test"}, %{})
      assert result.error =~ "Missing required context"
    end
  end

  # ---------------------------------------------------------------------------
  # ResumeJob Tests
  # ---------------------------------------------------------------------------

  describe "ResumeJob" do
    test "provides display_name" do
      assert ResumeJob.display_name() == "Resuming job..."
    end

    test "summarizes output correctly" do
      assert ResumeJob.summarize_output(%{status: "resumed", name: "Test"}) == "Resumed: Test"
      assert ResumeJob.summarize_output(%{error: "some error"}) == "Error"
      assert ResumeJob.summarize_output(%{}) == "Completed"
    end

    test "resumes a paused job" do
      %{context: context} = create_test_context()

      CreateJob.run(
        %{
          name: "Resume Me",
          trigger_prompt: "P",
          schedule_type: "one_time",
          scheduled_at: one_hour_from_now()
        },
        context
      )

      # Pause first
      PauseJob.run(%{name: "Resume Me"}, context)

      # Then resume
      assert {:ok, result} = ResumeJob.run(%{name: "Resume Me"}, context)
      assert result.status == "resumed"
      assert result.name == "Resume Me"
      assert result.message =~ "resumed"
    end

    test "returns error for active job" do
      %{context: context} = create_test_context()

      CreateJob.run(
        %{
          name: "Already Active",
          trigger_prompt: "P",
          schedule_type: "one_time",
          scheduled_at: one_hour_from_now()
        },
        context
      )

      assert {:ok, result} = ResumeJob.run(%{name: "Already Active"}, context)
      assert result.error =~ "already active"
    end

    test "returns error for stopped job" do
      %{context: context} = create_test_context()

      CreateJob.run(
        %{
          name: "Resume Stopped",
          trigger_prompt: "P",
          schedule_type: "one_time",
          scheduled_at: one_hour_from_now()
        },
        context
      )

      StopJob.run(%{name: "Resume Stopped"}, context)

      assert {:ok, result} = ResumeJob.run(%{name: "Resume Stopped"}, context)
      # Job not found because stopped jobs are filtered out
      assert result.error =~ "not found" or result.error =~ "Stopped"
    end

    test "returns error for non-existent job" do
      %{context: context} = create_test_context()

      assert {:ok, result} = ResumeJob.run(%{name: "Non-existent"}, context)
      assert result.error =~ "not found"
    end

    test "returns error with missing context" do
      assert {:ok, result} = ResumeJob.run(%{name: "Test"}, %{})
      assert result.error =~ "Missing required context"
    end
  end

  # ---------------------------------------------------------------------------
  # Integration Tests
  # ---------------------------------------------------------------------------

  describe "job lifecycle integration" do
    test "full workflow: create, pause, resume, stop" do
      %{context: context} = create_test_context()

      # Create
      assert {:ok, %{status: "created"}} =
               CreateJob.run(
                 %{
                   name: "Lifecycle Job",
                   trigger_prompt: "Test lifecycle",
                   schedule_type: "one_time",
                   scheduled_at: one_hour_from_now()
                 },
                 context
               )

      # List to verify
      assert {:ok, %{count: 1}} = ListJobs.run(%{}, context)

      # Pause
      assert {:ok, %{status: "paused"}} = PauseJob.run(%{name: "Lifecycle Job"}, context)

      # Resume
      assert {:ok, %{status: "resumed"}} = ResumeJob.run(%{name: "Lifecycle Job"}, context)

      # Update
      assert {:ok, %{status: "updated"}} =
               UpdateJob.run(%{name: "Lifecycle Job", description: "Updated"}, context)

      # Stop
      assert {:ok, %{status: "stopped"}} = StopJob.run(%{name: "Lifecycle Job"}, context)

      # Verify stopped job not in list
      assert {:ok, %{count: 0}} = ListJobs.run(%{}, context)
    end

    test "tools work with string keys in context" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      string_context = %{
        "user_id" => user.id,
        "conversation_id" => conversation.id
      }

      assert {:ok, %{status: "created"}} =
               CreateJob.run(
                 %{
                   name: "String Keys Job",
                   trigger_prompt: "Test",
                   schedule_type: "one_time",
                   scheduled_at: one_hour_from_now()
                 },
                 string_context
               )

      assert {:ok, %{count: 1}} = ListJobs.run(%{}, string_context)
    end

    test "multiple jobs in same conversation" do
      %{context: context} = create_test_context()

      for i <- 1..5 do
        CreateJob.run(
          %{
            name: "Job #{i}",
            trigger_prompt: "Prompt #{i}",
            schedule_type: "one_time",
            scheduled_at: one_hour_from_now()
          },
          context
        )
      end

      assert {:ok, result} = ListJobs.run(%{}, context)
      assert result.count == 5
    end

    test "jobs are scoped to conversation" do
      # Create two separate conversations
      %{context: context1} = create_test_context()
      %{context: context2} = create_test_context()

      # Create jobs in each
      CreateJob.run(
        %{
          name: "Conv1 Job",
          trigger_prompt: "P",
          schedule_type: "one_time",
          scheduled_at: one_hour_from_now()
        },
        context1
      )

      CreateJob.run(
        %{
          name: "Conv2 Job",
          trigger_prompt: "P",
          schedule_type: "one_time",
          scheduled_at: one_hour_from_now()
        },
        context2
      )

      # Verify each conversation only sees its own jobs
      {:ok, result1} = ListJobs.run(%{}, context1)
      {:ok, result2} = ListJobs.run(%{}, context2)

      assert result1.count == 1
      assert result2.count == 1
      assert hd(result1.jobs).name == "Conv1 Job"
      assert hd(result2.jobs).name == "Conv2 Job"
    end

    test "paused jobs still appear in list" do
      %{context: context} = create_test_context()

      CreateJob.run(
        %{
          name: "Paused Listed",
          trigger_prompt: "P",
          schedule_type: "one_time",
          scheduled_at: one_hour_from_now()
        },
        context
      )

      PauseJob.run(%{name: "Paused Listed"}, context)

      {:ok, result} = ListJobs.run(%{}, context)
      assert result.count == 1
      assert hd(result.jobs).status == :paused
    end
  end
end
