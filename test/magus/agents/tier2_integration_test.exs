defmodule Magus.Agents.Tier2IntegrationTest do
  @moduledoc """
  Integration tests for Tier 2 agent control plane features:
  task assignment inbox events and approval request/response cycle.
  """

  use Magus.DataCase, async: true

  import Magus.Generators

  # ============================================================================
  # Test 1: Task assignment cycle
  # ============================================================================

  test "assign → event created → reassign → old dismissed, new created" do
    user = generate(user())
    agent1 = custom_agent(user, %{name: "Agent1"})
    agent2 = custom_agent(user, %{name: "Agent2"})
    conv = generate(conversation(actor: user))

    # Assign to agent1
    {:ok, task} =
      Magus.Plan.create_task(
        conv.id,
        %{title: "Do work", assigned_to_custom_agent_id: agent1.id},
        actor: user
      )

    {:ok, events1} = Magus.Agents.list_pending_events(agent1.id, actor: user)
    assert length(events1) == 1
    assert hd(events1).event_type == :task_assigned

    # Reassign to agent2
    {:ok, _} =
      Magus.Plan.update_task(task, %{assigned_to_custom_agent_id: agent2.id}, actor: user)

    # Agent1's event should be dismissed (not in pending list)
    {:ok, dismissed} = Magus.Agents.list_pending_events(agent1.id, actor: user)
    assert dismissed == []

    # Agent2 should have the event
    {:ok, events2} = Magus.Agents.list_pending_events(agent2.id, actor: user)
    assert length(events2) == 1
    assert hd(events2).event_type == :task_assigned
  end

  # ============================================================================
  # Test 2: Approval request → response cycle
  # ============================================================================

  test "request approval → waiting event → button click → resolved" do
    user = generate(user())
    agent = custom_agent(user, %{name: "ApprovalAgent"})
    conv = generate(conversation(actor: user, custom_agent_id: agent.id))

    # Request approval (tool call)
    context = %{user_id: user.id, conversation_id: conv.id}

    {:ok, result} =
      Magus.Agents.Tools.Tasks.RequestApproval.run(
        %{"question" => "Deploy to prod?", "options" => ["Yes", "No"]},
        context
      )

    assert result.status == "pending"

    # Verify waiting event exists
    {:ok, events} = Magus.Agents.list_agent_events(agent.id, actor: user)
    approval = Enum.find(events, &(&1.event_type == :approval_response))
    assert approval != nil
    assert approval.status == :waiting

    # Simulate button click (sends "Yes: Deploy to prod?")
    signal = %{
      type: "message.user",
      data: %{
        text: "Yes: Deploy to prod?",
        conversation_id: conv.id,
        message_id: Ash.UUIDv7.generate()
      }
    }

    plugin_context = %{
      agent: %{
        id: "conv:#{conv.id}",
        state: %{user_id: user.id, conversation_id: conv.id}
      }
    }

    {:ok, :continue} =
      Magus.Agents.Plugins.InboxEventPlugin.handle_signal(signal, plugin_context)

    # Verify event resolved
    resolved = Ash.get!(Magus.Agents.AgentInboxEvent, approval.id, actor: user)
    assert resolved.status == :resolved
    assert resolved.resolved_by == :user
    assert resolved.resolution_note =~ "Yes"
  end
end
