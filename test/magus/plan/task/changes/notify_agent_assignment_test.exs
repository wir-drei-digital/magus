defmodule Magus.Plan.Task.Changes.NotifyAgentAssignmentTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents
  alias Magus.Plan

  defp create_context do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
    agent = custom_agent(user)
    %{user: user, conversation: conversation, agent: agent}
  end

  # ---------------------------------------------------------------------------
  # New assignment (nil → agent) creates inbox event
  # ---------------------------------------------------------------------------

  describe "create task with assignment" do
    test "creates a task_assigned inbox event for the agent" do
      %{user: user, conversation: conversation, agent: agent} = create_context()

      {:ok, task} =
        Plan.create_task(
          conversation.id,
          %{title: "Do the thing", assigned_to_custom_agent_id: agent.id},
          actor: user
        )

      idempotency_key = "task_assigned:#{task.id}:#{agent.id}"

      assert {:ok, [event | _]} =
               Agents.get_event_by_idempotency_key(idempotency_key, actor: user)

      assert event.event_type == :task_assigned
      assert event.agent_id == agent.id
      assert event.status == :pending
      assert event.urgency == :immediate
      assert event.title == "Task assigned: Do the thing"
      assert event.source_id == to_string(conversation.id)
    end

    test "does not create an inbox event when no agent is assigned" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, _task} =
        Plan.create_task(conversation.id, %{title: "Unassigned task"}, actor: user)

      {:ok, events} = Agents.list_user_activity(actor: user)
      assert events == []
    end

    test "does not crash when no agent is assigned" do
      %{user: user, conversation: conversation} = create_context()

      assert {:ok, _task} =
               Plan.create_task(conversation.id, %{title: "Plain task"}, actor: user)
    end
  end

  # ---------------------------------------------------------------------------
  # Reassignment (A → B) dismisses old event and creates new event
  # ---------------------------------------------------------------------------

  describe "reassignment" do
    test "dismisses the old event and creates a new one for the new agent" do
      %{user: user, conversation: conversation, agent: agent_a} = create_context()
      agent_b = custom_agent(user)

      {:ok, task} =
        Plan.create_task(
          conversation.id,
          %{title: "Reassignable task", assigned_to_custom_agent_id: agent_a.id},
          actor: user
        )

      old_key = "task_assigned:#{task.id}:#{agent_a.id}"
      assert {:ok, [_ | _]} = Agents.get_event_by_idempotency_key(old_key, actor: user)

      {:ok, _updated} =
        Plan.update_task(task, %{assigned_to_custom_agent_id: agent_b.id}, actor: user)

      # Old event should be dismissed
      assert {:ok, [old_event | _]} = Agents.get_event_by_idempotency_key(old_key, actor: user)
      assert old_event.status == :dismissed

      # New event should exist and be pending
      new_key = "task_assigned:#{task.id}:#{agent_b.id}"
      assert {:ok, [new_event | _]} = Agents.get_event_by_idempotency_key(new_key, actor: user)
      assert new_event.status == :pending
      assert new_event.agent_id == agent_b.id
    end
  end

  # ---------------------------------------------------------------------------
  # Unassignment (A → nil) does not create a new event
  # ---------------------------------------------------------------------------

  describe "unassignment" do
    test "does not create a new event when unassigning" do
      %{user: user, conversation: conversation, agent: agent} = create_context()

      {:ok, task} =
        Plan.create_task(
          conversation.id,
          %{title: "Was assigned", assigned_to_custom_agent_id: agent.id},
          actor: user
        )

      {:ok, _updated} =
        Plan.update_task(task, %{assigned_to_custom_agent_id: nil}, actor: user)

      # Only the original event should exist (for the initial assignment)
      {:ok, events} = Agents.list_agent_events(agent.id, actor: user)
      refute Enum.any?(events, fn e -> e.status == :pending end)
    end
  end

  # ---------------------------------------------------------------------------
  # No change (A → A) does not create duplicate events
  # ---------------------------------------------------------------------------

  describe "no-op update (same agent)" do
    test "does not create a duplicate event when agent does not change" do
      %{user: user, conversation: conversation, agent: agent} = create_context()

      {:ok, task} =
        Plan.create_task(
          conversation.id,
          %{title: "Stable task", assigned_to_custom_agent_id: agent.id},
          actor: user
        )

      # Update a non-assignment field — agent stays the same
      {:ok, _updated} = Plan.update_task(task, %{title: "Stable task (renamed)"}, actor: user)

      {:ok, events} = Agents.list_agent_events(agent.id, actor: user)
      assert length(events) == 1
    end

    test "does not create a duplicate event when same agent is explicitly set again" do
      %{user: user, conversation: conversation, agent: agent} = create_context()

      {:ok, task} =
        Plan.create_task(
          conversation.id,
          %{title: "Same agent", assigned_to_custom_agent_id: agent.id},
          actor: user
        )

      # Re-set to the same agent
      {:ok, _updated} =
        Plan.update_task(task, %{assigned_to_custom_agent_id: agent.id}, actor: user)

      {:ok, events} = Agents.list_agent_events(agent.id, actor: user)
      assert length(events) == 1
    end
  end
end
