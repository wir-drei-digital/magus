defmodule Magus.Plan.Task.Changes.NotifyTaskCompletionTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents
  alias Magus.Plan

  defp create_context do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
    orchestrator = custom_agent(user, %{name: "Orchestrator"})
    worker = custom_agent(user, %{name: "Worker"})
    %{user: user, conversation: conversation, orchestrator: orchestrator, worker: worker}
  end

  # ---------------------------------------------------------------------------
  # Notifies assigning agent when a different agent completes the task
  # ---------------------------------------------------------------------------

  describe "task completed by different agent" do
    test "creates an agent_message inbox event for the assigning agent" do
      %{user: user, conversation: conversation, orchestrator: orchestrator, worker: worker} =
        create_context()

      {:ok, task} =
        Plan.create_task(
          conversation.id,
          %{
            title: "Do work",
            assigned_to_custom_agent_id: worker.id,
            assigned_by_custom_agent_id: orchestrator.id
          },
          actor: user
        )

      {:ok, _} = Plan.update_task(task, %{status: :done}, actor: user)

      idempotency_key = "task_done:#{task.id}"

      assert {:ok, [event | _]} =
               Agents.get_event_by_idempotency_key(idempotency_key, actor: user)

      assert event.agent_id == orchestrator.id
      assert event.event_type == :agent_message
      assert event.status == :pending
      assert event.urgency == :immediate
      assert event.title == "Task completed: Do work"
      assert event.payload["task_id"] == task.id
      assert event.payload["completed_by_agent_id"] == worker.id
    end

    test "sets conversation_id in event payload" do
      %{user: user, conversation: conversation, orchestrator: orchestrator, worker: worker} =
        create_context()

      {:ok, task} =
        Plan.create_task(
          conversation.id,
          %{
            title: "Payload task",
            assigned_to_custom_agent_id: worker.id,
            assigned_by_custom_agent_id: orchestrator.id
          },
          actor: user
        )

      {:ok, _} = Plan.update_task(task, %{status: :done}, actor: user)

      idempotency_key = "task_done:#{task.id}"

      assert {:ok, [event | _]} =
               Agents.get_event_by_idempotency_key(idempotency_key, actor: user)

      assert event.payload["conversation_id"] == task.conversation_id
    end

    test "is idempotent — second completion update does not create a duplicate event" do
      %{user: user, conversation: conversation, orchestrator: orchestrator, worker: worker} =
        create_context()

      {:ok, task} =
        Plan.create_task(
          conversation.id,
          %{
            title: "Idempotent task",
            assigned_to_custom_agent_id: worker.id,
            assigned_by_custom_agent_id: orchestrator.id
          },
          actor: user
        )

      {:ok, done_task} = Plan.update_task(task, %{status: :done}, actor: user)
      # Update again (status is already :done — should not trigger again)
      {:ok, _} = Plan.update_task(done_task, %{title: "Idempotent task (renamed)"}, actor: user)

      {:ok, events} = Agents.list_agent_events(orchestrator.id, actor: user)
      completion_events = Enum.filter(events, &(&1.event_type == :agent_message))
      assert length(completion_events) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Includes result_summary in event payload and summary
  # ---------------------------------------------------------------------------

  describe "result_summary in completion event" do
    test "includes result_summary in event payload when task has result_summary set" do
      %{user: user, conversation: conversation, orchestrator: orchestrator, worker: worker} =
        create_context()

      {:ok, task} =
        Plan.create_task(
          conversation.id,
          %{
            title: "Research task",
            assigned_to_custom_agent_id: worker.id,
            assigned_by_custom_agent_id: orchestrator.id
          },
          actor: user
        )

      {:ok, _} =
        Plan.update_task(task, %{status: :done, result_summary: "Elixir is great."}, actor: user)

      idempotency_key = "task_done:#{task.id}"

      assert {:ok, [event | _]} =
               Agents.get_event_by_idempotency_key(idempotency_key, actor: user)

      assert event.payload["result_summary"] == "Elixir is great."
    end

    test "event summary includes result_summary preview when set" do
      %{user: user, conversation: conversation, orchestrator: orchestrator, worker: worker} =
        create_context()

      {:ok, task} =
        Plan.create_task(
          conversation.id,
          %{
            title: "Summary task",
            assigned_to_custom_agent_id: worker.id,
            assigned_by_custom_agent_id: orchestrator.id
          },
          actor: user
        )

      {:ok, _} =
        Plan.update_task(task, %{status: :done, result_summary: "The answer is 42."}, actor: user)

      idempotency_key = "task_done:#{task.id}"

      assert {:ok, [event | _]} =
               Agents.get_event_by_idempotency_key(idempotency_key, actor: user)

      assert event.summary =~ "The answer is 42."
    end

    test "event summary preview is truncated to 200 characters" do
      %{user: user, conversation: conversation, orchestrator: orchestrator, worker: worker} =
        create_context()

      {:ok, task} =
        Plan.create_task(
          conversation.id,
          %{
            title: "Long summary task",
            assigned_to_custom_agent_id: worker.id,
            assigned_by_custom_agent_id: orchestrator.id
          },
          actor: user
        )

      long_summary = String.duplicate("x", 500)

      {:ok, _} =
        Plan.update_task(task, %{status: :done, result_summary: long_summary}, actor: user)

      idempotency_key = "task_done:#{task.id}"

      assert {:ok, [event | _]} =
               Agents.get_event_by_idempotency_key(idempotency_key, actor: user)

      # summary = "Completed by <name>: <200 chars of result_summary>"
      # Total is longer than 200 but the result_summary portion is capped at 200
      result_portion = String.slice(long_summary, 0, 200)
      assert event.summary =~ result_portion
      refute event.summary =~ String.duplicate("x", 201)
    end

    test "event payload result_summary is nil when task has no result_summary" do
      %{user: user, conversation: conversation, orchestrator: orchestrator, worker: worker} =
        create_context()

      {:ok, task} =
        Plan.create_task(
          conversation.id,
          %{
            title: "No summary task",
            assigned_to_custom_agent_id: worker.id,
            assigned_by_custom_agent_id: orchestrator.id
          },
          actor: user
        )

      {:ok, _} = Plan.update_task(task, %{status: :done}, actor: user)

      idempotency_key = "task_done:#{task.id}"

      assert {:ok, [event | _]} =
               Agents.get_event_by_idempotency_key(idempotency_key, actor: user)

      assert event.payload["result_summary"] == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Does NOT notify when agent completes own self-assigned task
  # ---------------------------------------------------------------------------

  describe "self-assigned task completion" do
    test "does not create agent_message event when assigned_by == assigned_to" do
      %{user: user, conversation: conversation, orchestrator: orchestrator} = create_context()

      {:ok, task} =
        Plan.create_task(
          conversation.id,
          %{
            title: "Self-work",
            assigned_to_custom_agent_id: orchestrator.id,
            assigned_by_custom_agent_id: orchestrator.id
          },
          actor: user
        )

      {:ok, _} = Plan.update_task(task, %{status: :done}, actor: user)

      {:ok, events} = Agents.list_agent_events(orchestrator.id, actor: user)
      assert Enum.all?(events, fn e -> e.event_type != :agent_message end)
    end
  end

  # ---------------------------------------------------------------------------
  # Does NOT notify when assigned_by_custom_agent_id is nil
  # ---------------------------------------------------------------------------

  describe "task without assigner" do
    test "does not create agent_message event when assigned_by_custom_agent_id is nil" do
      %{user: user, conversation: conversation, worker: worker} = create_context()

      {:ok, task} =
        Plan.create_task(
          conversation.id,
          %{
            title: "No assigner task",
            assigned_to_custom_agent_id: worker.id
          },
          actor: user
        )

      {:ok, _} = Plan.update_task(task, %{status: :done}, actor: user)

      {:ok, events} = Agents.list_agent_events(worker.id, actor: user)
      assert Enum.all?(events, fn e -> e.event_type != :agent_message end)
    end
  end

  # ---------------------------------------------------------------------------
  # Does NOT fire when status is already :done (no transition)
  # ---------------------------------------------------------------------------

  describe "already done task" do
    test "does not create a second event when task was already done" do
      %{user: user, conversation: conversation, orchestrator: orchestrator, worker: worker} =
        create_context()

      {:ok, task} =
        Plan.create_task(
          conversation.id,
          %{
            title: "Already done",
            assigned_to_custom_agent_id: worker.id,
            assigned_by_custom_agent_id: orchestrator.id,
            status: :done
          },
          actor: user
        )

      # Update a non-status field — status stays :done but it's not a transition
      {:ok, _} = Plan.update_task(task, %{title: "Already done (renamed)"}, actor: user)

      {:ok, events} = Agents.list_agent_events(orchestrator.id, actor: user)
      completion_events = Enum.filter(events, &(&1.event_type == :agent_message))
      assert completion_events == []
    end
  end
end
