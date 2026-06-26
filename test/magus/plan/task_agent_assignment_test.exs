defmodule Magus.Plan.TaskAgentAssignmentTest do
  use Magus.ResourceCase, async: true

  alias Magus.Plan

  defp create_context do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
    agent = custom_agent(user)
    %{user: user, conversation: conversation, agent: agent}
  end

  # ---------------------------------------------------------------------------
  # assigned_to_custom_agent_id
  # ---------------------------------------------------------------------------

  describe "assigning a task to a custom agent" do
    test "creates a task with assigned_to_custom_agent_id set", %{} do
      %{user: user, conversation: conversation, agent: agent} = create_context()

      {:ok, task} =
        Plan.create_task(
          conversation.id,
          %{title: "Agent task", assigned_to_custom_agent_id: agent.id},
          actor: user
        )

      assert task.assigned_to_custom_agent_id == agent.id
    end

    test "assigned_to_custom_agent_id is nil by default", %{} do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} = Plan.create_task(conversation.id, %{title: "Plain task"}, actor: user)

      assert is_nil(task.assigned_to_custom_agent_id)
    end

    test "can update assigned_to_custom_agent_id on an existing task", %{} do
      %{user: user, conversation: conversation, agent: agent} = create_context()

      {:ok, task} = Plan.create_task(conversation.id, %{title: "Unassigned"}, actor: user)
      assert is_nil(task.assigned_to_custom_agent_id)

      {:ok, updated} =
        Plan.update_task(task, %{assigned_to_custom_agent_id: agent.id}, actor: user)

      assert updated.assigned_to_custom_agent_id == agent.id
    end

    test "can clear assigned_to_custom_agent_id by setting it to nil", %{} do
      %{user: user, conversation: conversation, agent: agent} = create_context()

      {:ok, task} =
        Plan.create_task(
          conversation.id,
          %{title: "Assigned", assigned_to_custom_agent_id: agent.id},
          actor: user
        )

      {:ok, updated} =
        Plan.update_task(task, %{assigned_to_custom_agent_id: nil}, actor: user)

      assert is_nil(updated.assigned_to_custom_agent_id)
    end
  end

  # ---------------------------------------------------------------------------
  # :blocked status with blocked_reason
  # ---------------------------------------------------------------------------

  describe "blocked status" do
    test "creates a task with :blocked status", %{} do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} =
        Plan.create_task(
          conversation.id,
          %{title: "Blocked task", status: :blocked},
          actor: user
        )

      assert task.status == :blocked
    end

    test "sets blocked_reason when blocking a task", %{} do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} = Plan.create_task(conversation.id, %{title: "Task"}, actor: user)

      {:ok, updated} =
        Plan.update_task(
          task,
          %{status: :blocked, blocked_reason: "Waiting for API credentials"},
          actor: user
        )

      assert updated.status == :blocked
      assert updated.blocked_reason == "Waiting for API credentials"
    end

    test "blocked_reason is nil by default", %{} do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} = Plan.create_task(conversation.id, %{title: "Task"}, actor: user)

      assert is_nil(task.blocked_reason)
    end

    test "can unblock a task by setting status back to :open", %{} do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} =
        Plan.create_task(
          conversation.id,
          %{title: "Task", status: :blocked, blocked_reason: "Some reason"},
          actor: user
        )

      {:ok, unblocked} =
        Plan.update_task(task, %{status: :open, blocked_reason: nil}, actor: user)

      assert unblocked.status == :open
      assert is_nil(unblocked.blocked_reason)
    end
  end

  # ---------------------------------------------------------------------------
  # waiting_on_user flag
  # ---------------------------------------------------------------------------

  describe "waiting_on_user flag" do
    test "defaults to false", %{} do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} = Plan.create_task(conversation.id, %{title: "Task"}, actor: user)

      assert task.waiting_on_user == false
    end

    test "can be set to true on create", %{} do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} =
        Plan.create_task(
          conversation.id,
          %{title: "Waiting task", waiting_on_user: true},
          actor: user
        )

      assert task.waiting_on_user == true
    end

    test "can be toggled via update", %{} do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} = Plan.create_task(conversation.id, %{title: "Task"}, actor: user)
      assert task.waiting_on_user == false

      {:ok, waiting} = Plan.update_task(task, %{waiting_on_user: true}, actor: user)
      assert waiting.waiting_on_user == true

      {:ok, not_waiting} = Plan.update_task(waiting, %{waiting_on_user: false}, actor: user)
      assert not_waiting.waiting_on_user == false
    end
  end
end
