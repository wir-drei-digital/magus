defmodule Magus.Agents.ControlPlaneIntegrationTest do
  @moduledoc """
  Integration tests for the agent control plane:
  inbox events, activity logs, plan tasks with agent assignment, and AgentRun linkage.
  """

  use Magus.DataCase, async: true

  import Magus.Generators

  # ============================================================================
  # Full flow: inbox events and activity log
  # ============================================================================

  test "full flow: create agent, inbox events, activity log" do
    user = generate(user())
    agent = custom_agent(user)

    # Create 3 inbox events
    for i <- 1..3 do
      {:ok, _} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :content,
            urgency: :deferred,
            title: "Item #{i}",
            source_type: :integration
          },
          actor: user
        )
    end

    # Verify all 3 are listed as pending
    {:ok, events} = Magus.Agents.list_pending_events(agent.id, actor: user)
    assert length(events) == 3

    # Dismiss one
    {:ok, _} =
      Magus.Agents.dismiss_event(hd(events), %{resolution_note: "test"}, actor: user)

    {:ok, events} = Magus.Agents.list_pending_events(agent.id, actor: user)
    assert length(events) == 2

    # Create activity log
    {:ok, _} =
      Magus.Agents.create_activity_log(
        %{agent_id: agent.id, activity_type: :triage_completed, summary: "Test triage"},
        actor: user
      )

    {:ok, activity} = Magus.Agents.list_agent_activity(agent.id, actor: user)
    assert length(activity) == 1
  end

  # ============================================================================
  # Plan.Task with agent assignment
  # ============================================================================

  test "Plan.Task with agent assignment" do
    user = generate(user())
    agent = custom_agent(user)
    conv = generate(conversation(actor: user))

    {:ok, task} =
      Magus.Plan.create_task(
        conv.id,
        %{title: "Test task", assigned_to_custom_agent_id: agent.id},
        actor: user
      )

    assert task.assigned_to_custom_agent_id == agent.id

    {:ok, task} =
      Magus.Plan.update_task(task, %{status: :blocked, blocked_reason: "Waiting"}, actor: user)

    assert task.status == :blocked
    assert task.blocked_reason == "Waiting"
  end

  # ============================================================================
  # AgentRun linked to inbox event and task
  # ============================================================================

  test "AgentRun linked to event and task" do
    user = generate(user())
    agent = custom_agent(user)
    conv = generate(conversation(actor: user))

    {:ok, event} =
      Magus.Agents.create_inbox_event(
        %{
          agent_id: agent.id,
          event_type: :mention,
          urgency: :immediate,
          title: "Test",
          source_type: :conversation
        },
        actor: user
      )

    {:ok, task} = Magus.Plan.create_task(conv.id, %{title: "Task"}, actor: user)

    run =
      sub_agent_run(
        source_conversation_id: conv.id,
        event_id: event.id,
        task_id: task.id
      )

    assert run.event_id == event.id
    assert run.task_id == task.id
  end
end
