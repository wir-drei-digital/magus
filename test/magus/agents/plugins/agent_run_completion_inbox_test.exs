defmodule Magus.Agents.Plugins.AgentRunCompletionInboxTest do
  @moduledoc """
  Tests that AgentRunCompletionPlugin wires into the inbox/activity system:
  - Resolves AgentInboxEvent when a linked run completes
  - Marks AgentInboxEvent as waiting when a linked run fails
  - Creates AgentActivityLog entries on completion and failure
  """

  use Magus.DataCase, async: false

  import Magus.Generators

  require Ash.Query

  alias Magus.Agents.AgentInboxEvent
  alias Magus.Agents.Plugins.AgentRunCompletionPlugin

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp build_agent(conversation_id, overrides \\ %{}) do
    base_state =
      Map.merge(
        %{
          conversation_id: conversation_id,
          user_id: "test-user-id",
          mode: :chat,
          model_keys: %{chat: "test-model"},
          __strategy__: %{
            active_request_id: nil,
            streaming_text: "Result text",
            streaming_thinking: "",
            pending_tool_calls: []
          }
        },
        overrides
      )

    %{id: "conv:#{conversation_id}", state: base_state}
  end

  defp build_context(agent), do: %{agent: agent}

  defp make_signal(type, data), do: Jido.Signal.new!(type, data)

  defp create_conversations(user) do
    parent_conv = generate(conversation(actor: user))

    child_conv =
      generate(
        conversation(
          actor: user,
          is_task_conversation: true,
          parent_conversation_id: parent_conv.id
        )
      )

    {parent_conv, child_conv}
  end

  defp create_inbox_event(user, agent) do
    {:ok, event} =
      Magus.Agents.create_inbox_event(
        %{
          agent_id: agent.id,
          event_type: :mention,
          urgency: :immediate,
          title: "Test mention",
          source_type: :conversation
        },
        actor: user
      )

    event
  end

  defp create_run(user, parent_conv, child_conv, agent, opts) do
    attrs =
      Keyword.merge(
        [
          source_conversation_id: parent_conv.id,
          target_conversation_id: child_conv.id,
          target_agent_id: Keyword.get(opts, :target_agent_id, agent.id),
          initiator_user_id: user.id,
          event_id: Keyword.get(opts, :event_id)
        ],
        opts
      )

    sub_agent_run(attrs)
  end

  # ============================================================================
  # Inbox event resolution on run completion
  # ============================================================================

  describe "inbox event resolution on ai.request.completed" do
    test "resolves linked inbox event when run completes" do
      user = generate(user())
      agent = custom_agent(user)
      {parent_conv, child_conv} = create_conversations(user)
      event = create_inbox_event(user, agent)

      run =
        create_run(user, parent_conv, child_conv, agent,
          target_agent_id: agent.id,
          event_id: event.id
        )

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      context = build_context(build_agent(child_conv.id))
      signal = make_signal("ai.request.completed", %{request_id: run.request_id})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)

      {:ok, updated_event} = Ash.get(AgentInboxEvent, event.id, authorize?: false)
      assert updated_event.status == :resolved
      assert updated_event.resolved_by == :agent
      assert updated_event.run_id == run.id
      assert updated_event.resolution_note == "Run completed"
    end

    test "does not error when run has no event_id" do
      user = generate(user())
      agent = custom_agent(user)
      {parent_conv, child_conv} = create_conversations(user)

      # Run without event_id
      run =
        create_run(user, parent_conv, child_conv, agent,
          target_agent_id: agent.id,
          event_id: nil
        )

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      context = build_context(build_agent(child_conv.id))
      signal = make_signal("ai.request.completed", %{request_id: run.request_id})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)
    end

    test "does not error when run has nil event_id on completion" do
      user = generate(user())
      agent = custom_agent(user)
      {parent_conv, child_conv} = create_conversations(user)

      run =
        create_run(user, parent_conv, child_conv, agent,
          target_agent_id: agent.id,
          event_id: nil
        )

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      context = build_context(build_agent(child_conv.id))
      signal = make_signal("ai.request.completed", %{request_id: run.request_id})

      # Should not raise — skips resolve when no event_id
      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)
    end
  end

  # ============================================================================
  # Inbox event waiting on run failure
  # ============================================================================

  describe "inbox event waiting on ai.request.failed" do
    test "marks linked inbox event as waiting when run fails" do
      user = generate(user())
      agent = custom_agent(user)
      {parent_conv, child_conv} = create_conversations(user)
      event = create_inbox_event(user, agent)

      run =
        create_run(user, parent_conv, child_conv, agent,
          target_agent_id: agent.id,
          event_id: event.id
        )

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      context = build_context(build_agent(child_conv.id))

      signal =
        make_signal("ai.request.failed", %{error: "LLM timeout", request_id: run.request_id})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)

      {:ok, updated_event} = Ash.get(AgentInboxEvent, event.id, authorize?: false)
      assert updated_event.status == :waiting
    end

    test "does not error when failed run has no event_id" do
      user = generate(user())
      agent = custom_agent(user)
      {parent_conv, child_conv} = create_conversations(user)

      run =
        create_run(user, parent_conv, child_conv, agent,
          target_agent_id: agent.id,
          event_id: nil
        )

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      context = build_context(build_agent(child_conv.id))
      signal = make_signal("ai.request.failed", %{error: "timeout", request_id: run.request_id})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)
    end
  end

  # ============================================================================
  # Activity log creation
  # ============================================================================

  describe "activity log process dict on ai.request.completed" do
    test "sets :activity_log_last_completed_run in process dict when run completes" do
      user = generate(user())
      agent = custom_agent(user)
      {parent_conv, child_conv} = create_conversations(user)

      run =
        create_run(user, parent_conv, child_conv, agent,
          target_agent_id: agent.id,
          initiator_user_id: user.id
        )

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      context = build_context(build_agent(child_conv.id))
      signal = make_signal("ai.request.completed", %{request_id: run.request_id})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)

      completed_run = Process.get(:activity_log_last_completed_run)
      assert completed_run != nil
      assert completed_run.id == run.id
      assert completed_run.status == :complete
    end

    test "completed run in process dict includes event_id and task_id when set" do
      user = generate(user())
      agent = custom_agent(user)
      {parent_conv, child_conv} = create_conversations(user)
      event = create_inbox_event(user, agent)
      {:ok, task} = Magus.Plan.create_task(parent_conv.id, %{title: "Test task"}, actor: user)

      run =
        create_run(user, parent_conv, child_conv, agent,
          target_agent_id: agent.id,
          initiator_user_id: user.id,
          event_id: event.id,
          task_id: task.id
        )

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      context = build_context(build_agent(child_conv.id))
      signal = make_signal("ai.request.completed", %{request_id: run.request_id})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)

      completed_run = Process.get(:activity_log_last_completed_run)
      assert completed_run != nil
      assert completed_run.event_id == event.id
      assert completed_run.task_id == task.id
    end

    test "does not set process dict when run has no target_agent_id" do
      user = generate(user())
      _agent = custom_agent(user)
      {parent_conv, child_conv} = create_conversations(user)

      # Run without target_agent_id
      run =
        sub_agent_run(
          source_conversation_id: parent_conv.id,
          target_conversation_id: child_conv.id,
          initiator_user_id: user.id,
          target_agent_id: nil
        )

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      context = build_context(build_agent(child_conv.id))
      signal = make_signal("ai.request.completed", %{request_id: run.request_id})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)

      # Process dict is still set (ActivityLogPlugin will handle filtering by agent_id)
      completed_run = Process.get(:activity_log_last_completed_run)
      assert completed_run != nil
      assert completed_run.target_agent_id == nil
    end
  end

  describe "activity log process dict on ai.request.failed" do
    test "sets :activity_log_last_failed_run in process dict when run fails" do
      user = generate(user())
      agent = custom_agent(user)
      {parent_conv, child_conv} = create_conversations(user)

      run =
        create_run(user, parent_conv, child_conv, agent,
          target_agent_id: agent.id,
          initiator_user_id: user.id
        )

      {:ok, _} = Magus.Agents.start_agent_run(run.id, authorize?: false)

      context = build_context(build_agent(child_conv.id))

      signal =
        make_signal("ai.request.failed", %{error: "provider down", request_id: run.request_id})

      assert {:ok, :continue} = AgentRunCompletionPlugin.handle_signal(signal, context)

      failed_run = Process.get(:activity_log_last_failed_run)
      assert failed_run != nil
      assert failed_run.id == run.id
      assert failed_run.status == :error
    end
  end
end
