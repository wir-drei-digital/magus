defmodule Magus.Workflows.JobRunTest do
  @moduledoc """
  Tests for the JobRun resource.

  Tests cover:
  - JobRun creation and status transitions
  - Status updates (start, succeed, fail, retry)
  - Message linking (trigger and response)
  - Query actions (for_job, recent_for_job)
  - Authorization policies
  """
  use Magus.ResourceCase, async: true

  alias Magus.Workflows
  alias Magus.Chat

  setup do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
    job = job(conversation_id: conversation.id, user_id: user.id)

    %{user: user, conversation: conversation, job: job}
  end

  describe "JobRun.create" do
    test "creates run with default status", %{job: job} do
      {:ok, run} = Workflows.create_job_run(job.id, authorize?: false)

      assert run.status == :pending
      assert run.job_id == job.id
      assert run.retry_attempt == 0
      assert run.started_at != nil
      assert run.metadata == %{}
    end

    test "creates run with custom metadata", %{job: job} do
      {:ok, run} =
        Workflows.create_job_run(job.id, %{metadata: %{"custom" => "data"}}, authorize?: false)

      assert run.metadata == %{"custom" => "data"}
    end
  end

  describe "JobRun status transitions" do
    test "start sets status to running", %{job: job} do
      run = job_run(job_id: job.id)

      {:ok, started} = Workflows.start_job_run(run, authorize?: false)

      assert started.status == :running
      assert started.started_at != nil
    end

    test "succeed sets status to success and completed_at", %{job: job} do
      run = job_run(job_id: job.id)
      {:ok, started} = Workflows.start_job_run(run, authorize?: false)

      {:ok, succeeded} = Workflows.succeed_job_run(started, nil, authorize?: false)

      assert succeeded.status == :success
      assert succeeded.completed_at != nil
    end

    test "succeed can link response message", %{job: job, conversation: conversation, user: user} do
      run = job_run(job_id: job.id)
      {:ok, started} = Workflows.start_job_run(run, authorize?: false)

      # Create a message to link
      {:ok, message} =
        Chat.send_user_message(
          %{text: "Response", conversation_id: conversation.id},
          actor: user
        )

      {:ok, succeeded} = Workflows.succeed_job_run(started, message.id, authorize?: false)

      assert succeeded.response_message_id == message.id
    end

    test "fail sets status to failed with error message", %{job: job} do
      run = job_run(job_id: job.id)
      {:ok, started} = Workflows.start_job_run(run, authorize?: false)

      {:ok, failed} = Workflows.fail_job_run(started, "Something went wrong", authorize?: false)

      assert failed.status == :failed
      assert failed.error_message == "Something went wrong"
      assert failed.completed_at != nil
    end

    test "retry sets status to retrying and increments attempt", %{job: job} do
      run = job_run(job_id: job.id)
      assert run.retry_attempt == 0

      {:ok, retrying} = Workflows.retry_job_run(run, authorize?: false)

      assert retrying.status == :retrying
      assert retrying.retry_attempt == 1

      {:ok, retrying2} = Workflows.retry_job_run(retrying, authorize?: false)

      assert retrying2.retry_attempt == 2
    end
  end

  describe "JobRun message linking" do
    test "set_trigger_message links trigger message", %{
      job: job,
      conversation: conversation,
      user: user
    } do
      run = job_run(job_id: job.id)

      {:ok, message} =
        Chat.send_user_message(
          %{text: "Trigger", conversation_id: conversation.id},
          actor: user
        )

      {:ok, updated} =
        Workflows.set_job_run_trigger_message(run, message.id, authorize?: false)

      assert updated.trigger_message_id == message.id
    end
  end

  describe "JobRun queries" do
    test "for_job returns runs for specific job", %{job: job} do
      run1 = job_run(job_id: job.id)
      run2 = job_run(job_id: job.id)

      # Create another job with a run
      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{}, actor: user)
      other_job = job(conversation_id: conv.id, user_id: user.id)
      _other_run = job_run(job_id: other_job.id)

      {:ok, runs} = Workflows.list_runs_for_job(job.id, authorize?: false)

      run_ids = Enum.map(runs, & &1.id)
      assert run1.id in run_ids
      assert run2.id in run_ids
      assert length(runs) == 2
    end

    test "for_job returns runs sorted by started_at desc", %{job: job} do
      run1 = job_run(job_id: job.id)
      Process.sleep(10)
      run2 = job_run(job_id: job.id)
      Process.sleep(10)
      run3 = job_run(job_id: job.id)

      {:ok, runs} = Workflows.list_runs_for_job(job.id, authorize?: false)

      # Most recent first
      assert Enum.at(runs, 0).id == run3.id
      assert Enum.at(runs, 1).id == run2.id
      assert Enum.at(runs, 2).id == run1.id
    end

    test "recent_for_job limits results", %{job: job} do
      # Create 15 runs
      for _ <- 1..15 do
        job_run(job_id: job.id)
      end

      # Default limit is 10
      {:ok, runs} = Workflows.list_recent_runs_for_job(job.id, authorize?: false)

      assert length(runs) == 10
    end

    test "recent_for_job respects custom limit", %{job: job} do
      for _ <- 1..10 do
        job_run(job_id: job.id)
      end

      {:ok, runs} = Workflows.list_recent_runs_for_job(job.id, %{limit: 5}, authorize?: false)

      assert length(runs) == 5
    end
  end

  describe "authorization" do
    test "user can read runs for own jobs", %{user: user, job: job} do
      run = job_run(job_id: job.id)

      {:ok, runs} = Workflows.list_runs_for_job(job.id, actor: user)

      assert length(runs) == 1
      assert hd(runs).id == run.id
    end

    test "user cannot read runs for other user's jobs" do
      user1 = generate(user())
      user2 = generate(user())
      {:ok, conv} = Chat.create_conversation(%{}, actor: user1)
      job = job(conversation_id: conv.id, user_id: user1.id)
      _run = job_run(job_id: job.id)

      {:ok, runs} = Workflows.list_runs_for_job(job.id, actor: user2)

      # Authorization filters results
      assert Enum.empty?(runs)
    end
  end

  describe "cascading delete" do
    test "deleting job deletes associated runs", %{job: job} do
      _run = job_run(job_id: job.id)

      # Delete the job
      :ok = Ash.destroy!(job, authorize?: false)

      # Runs should be deleted too - list returns empty
      {:ok, runs} = Workflows.list_runs_for_job(job.id, authorize?: false)
      assert runs == []
    end
  end

  describe "complete run lifecycle" do
    test "full lifecycle: create -> start -> succeed", %{job: job} do
      {:ok, run} = Workflows.create_job_run(job.id, authorize?: false)
      assert run.status == :pending

      {:ok, started} = Workflows.start_job_run(run, authorize?: false)
      assert started.status == :running

      {:ok, succeeded} = Workflows.succeed_job_run(started, nil, authorize?: false)
      assert succeeded.status == :success
      assert succeeded.completed_at != nil
    end

    test "full lifecycle: create -> start -> fail", %{job: job} do
      {:ok, run} = Workflows.create_job_run(job.id, authorize?: false)
      {:ok, started} = Workflows.start_job_run(run, authorize?: false)
      {:ok, failed} = Workflows.fail_job_run(started, "Error occurred", authorize?: false)

      assert failed.status == :failed
      assert failed.error_message == "Error occurred"
    end

    test "full lifecycle with retries: create -> start -> fail -> retry -> succeed", %{job: job} do
      {:ok, run} = Workflows.create_job_run(job.id, authorize?: false)
      {:ok, started} = Workflows.start_job_run(run, authorize?: false)
      {:ok, retrying} = Workflows.retry_job_run(started, authorize?: false)

      assert retrying.status == :retrying
      assert retrying.retry_attempt == 1

      # Second attempt succeeds
      {:ok, succeeded} = Workflows.succeed_job_run(retrying, nil, authorize?: false)

      assert succeeded.status == :success
      assert succeeded.retry_attempt == 1
    end
  end
end
