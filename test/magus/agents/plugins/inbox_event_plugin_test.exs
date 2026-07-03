defmodule Magus.Agents.Plugins.InboxEventPluginTest do
  @moduledoc """
  Unit tests for InboxEventPlugin — verifies that @mentions in user messages
  dispatch directly to the mentioned agent via RunOrchestrator, suppress the
  main agent's response, and strip @handles from the objective text.
  """

  use Magus.DataCase, async: true

  import Magus.Generators

  require Ash.Query

  alias Magus.Agents.Plugins.InboxEventPlugin

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp build_agent(user_id, conversation_id) do
    %{
      id: "conv:#{conversation_id}",
      state: %{
        user_id: user_id,
        conversation_id: conversation_id,
        mode: :chat,
        model_keys: %{chat: "test-model"}
      }
    }
  end

  defp build_context(agent) do
    %{agent: agent}
  end

  defp make_message_user_signal(text, conversation_id, message_id) do
    Jido.Signal.new!("message.user", %{
      text: text,
      conversation_id: conversation_id,
      message_id: message_id
    })
  end

  defp agent_runs_for(agent_id) do
    Magus.Agents.AgentRun
    |> Ash.Query.filter(target_agent_id == ^agent_id)
    |> Ash.read!(authorize?: false)
  end

  # ============================================================================
  # Plugin Metadata
  # ============================================================================

  describe "plugin metadata" do
    test "has correct name and state_key" do
      assert InboxEventPlugin.name() == "inbox_event"
      assert InboxEventPlugin.state_key() == :inbox_event
    end

    test "subscribes to message.user signal pattern" do
      assert "message.user" in InboxEventPlugin.signal_patterns()
    end
  end

  # ============================================================================
  # Non-mention messages
  # ============================================================================

  describe "handle_signal/2 with no mentions" do
    test "returns {:ok, :continue} without creating any events" do
      user = generate(user())
      conv_id = Ash.UUIDv7.generate()
      agent = build_agent(user.id, conv_id)
      context = build_context(agent)

      signal =
        make_message_user_signal("hello there, no mentions here", conv_id, Ash.UUIDv7.generate())

      assert {:ok, :continue} = InboxEventPlugin.handle_signal(signal, context)
    end

    test "passes through non-message.user signals" do
      user = generate(user())
      conv_id = Ash.UUIDv7.generate()
      agent = build_agent(user.id, conv_id)
      context = build_context(agent)

      other_signal = Jido.Signal.new!("message.cancel", %{})

      assert {:ok, :continue} = InboxEventPlugin.handle_signal(other_signal, context)
    end
  end

  # ============================================================================
  # Mention detection and dispatch
  # ============================================================================

  describe "handle_signal/2 with @mentions" do
    test "overrides with Noop when an active agent is mentioned" do
      user = generate(user())
      {:ok, conversation} = Magus.Chat.create_conversation(%{}, actor: user)
      message_id = Ash.UUIDv7.generate()
      mentioned = custom_agent(user, %{is_paused: false})

      agent = build_agent(user.id, conversation.id)
      context = build_context(agent)

      signal =
        make_message_user_signal(
          "hey @#{mentioned.handle} do this",
          conversation.id,
          message_id
        )

      assert {:ok, {:override, Jido.Actions.Control.Noop}} =
               InboxEventPlugin.handle_signal(signal, context)
    end

    test "skips paused agents and returns :continue" do
      user = generate(user())
      conv_id = Ash.UUIDv7.generate()
      message_id = Ash.UUIDv7.generate()
      paused = custom_agent(user, %{is_paused: true})

      agent = build_agent(user.id, conv_id)
      context = build_context(agent)
      signal = make_message_user_signal("hey @#{paused.handle} do something", conv_id, message_id)

      assert {:ok, :continue} = InboxEventPlugin.handle_signal(signal, context)
      assert agent_runs_for(paused.id) == []
    end

    test "dispatches only for active agents when mixed paused/active" do
      user = generate(user())
      {:ok, conversation} = Magus.Chat.create_conversation(%{}, actor: user)
      message_id = Ash.UUIDv7.generate()
      paused = custom_agent(user, %{is_paused: true})
      active = custom_agent(user, %{is_paused: false})

      agent = build_agent(user.id, conversation.id)
      context = build_context(agent)

      signal =
        make_message_user_signal(
          "hey @#{paused.handle} and @#{active.handle} do this",
          conversation.id,
          message_id
        )

      assert {:ok, {:override, Jido.Actions.Control.Noop}} =
               InboxEventPlugin.handle_signal(signal, context)

      assert agent_runs_for(paused.id) == []
      assert length(agent_runs_for(active.id)) == 1
    end

    test "does not create inbox events (dispatch only)" do
      user = generate(user())
      {:ok, conversation} = Magus.Chat.create_conversation(%{}, actor: user)
      mentioned = custom_agent(user, %{is_paused: false})

      agent = build_agent(user.id, conversation.id)
      context = build_context(agent)

      signal =
        make_message_user_signal(
          "@#{mentioned.handle} help",
          conversation.id,
          Ash.UUIDv7.generate()
        )

      InboxEventPlugin.handle_signal(signal, context)

      inbox_events =
        Magus.Agents.AgentInboxEvent
        |> Ash.Query.filter(agent_id == ^mentioned.id)
        |> Ash.read!(authorize?: false)

      assert inbox_events == []
    end
  end

  # ============================================================================
  # Direct dispatch (bypasses triage)
  # ============================================================================

  describe "direct dispatch via RunOrchestrator" do
    test "creates an AgentRun for a mentioned agent (skips triage)" do
      user = generate(user())
      {:ok, conversation} = Magus.Chat.create_conversation(%{}, actor: user)
      conv_id = conversation.id
      message_id = Ash.UUIDv7.generate()
      agent_record = custom_agent(user, %{is_paused: false})

      agent = build_agent(user.id, conv_id)
      context = build_context(agent)
      signal = make_message_user_signal("hey @#{agent_record.handle} help", conv_id, message_id)

      assert {:ok, {:override, Jido.Actions.Control.Noop}} =
               InboxEventPlugin.handle_signal(signal, context)

      runs =
        Magus.Agents.AgentRun
        |> Ash.Query.filter(
          target_agent_id == ^agent_record.id and
            idempotency_key == ^"mention:#{message_id}:#{agent_record.id}"
        )
        |> Ash.read!(authorize?: false)

      assert length(runs) == 1
      run = hd(runs)
      assert run.kind == :consult
      assert run.source_conversation_id == conv_id
      assert run.source_message_id == message_id
      assert run.metadata["trigger"] == "mention"
      assert run.metadata["agent_handle"] == agent_record.handle
    end

    test "strips @handles from objective text" do
      user = generate(user())
      {:ok, conversation} = Magus.Chat.create_conversation(%{}, actor: user)
      agent_record = custom_agent(user, %{is_paused: false})

      agent = build_agent(user.id, conversation.id)
      context = build_context(agent)

      signal =
        make_message_user_signal(
          "@#{agent_record.handle} do the thing",
          conversation.id,
          Ash.UUIDv7.generate()
        )

      InboxEventPlugin.handle_signal(signal, context)

      [run] = agent_runs_for(agent_record.id)
      refute String.contains?(run.objective, "@#{agent_record.handle}")
      assert String.contains?(run.objective, "do the thing")
    end

    test "passes custom agent model_key in the run" do
      user = generate(user())
      {:ok, conversation} = Magus.Chat.create_conversation(%{}, actor: user)
      agent_record = custom_agent(user, %{is_paused: false})

      agent = build_agent(user.id, conversation.id)
      context = build_context(agent)

      signal =
        make_message_user_signal(
          "@#{agent_record.handle} help",
          conversation.id,
          Ash.UUIDv7.generate()
        )

      InboxEventPlugin.handle_signal(signal, context)

      runs = agent_runs_for(agent_record.id)

      if agent_record.model_id do
        [run] = runs
        assert is_binary(run.model_key)
      end
    end

    test "skips dispatch when source equals target (home conversation)" do
      user = generate(user())
      agent_record = custom_agent(user, %{is_paused: false})

      # Create home conversation for this agent
      {:ok, home_conv} = Magus.Agents.Support.HomeConversation.ensure(user.id, agent_record.id)

      agent = build_agent(user.id, home_conv.id)
      context = build_context(agent)

      signal =
        make_message_user_signal(
          "@#{agent_record.handle} help",
          home_conv.id,
          Ash.UUIDv7.generate()
        )

      # Should return :continue since dispatch was skipped (same conversation)
      assert {:ok, :continue} = InboxEventPlugin.handle_signal(signal, context)
      assert agent_runs_for(agent_record.id) == []
    end

    test "dispatch failure does not block the signal" do
      user = generate(user())
      # Use a non-existent conversation_id to trigger dispatch failure
      conv_id = Ash.UUIDv7.generate()
      message_id = Ash.UUIDv7.generate()
      agent_record = custom_agent(user, %{is_paused: false})

      agent = build_agent(user.id, conv_id)
      context = build_context(agent)
      signal = make_message_user_signal("hey @#{agent_record.handle} help", conv_id, message_id)

      # Even if dispatch fails, the plugin should not crash
      # Returns :continue because no dispatch succeeded
      assert {:ok, :continue} = InboxEventPlugin.handle_signal(signal, context)
    end
  end

  # ============================================================================
  # Approval response wakes the requesting agent
  # ============================================================================

  describe "handle_signal/2 with approval responses" do
    test "resolves the waiting event and creates an :immediate approval_response event" do
      user = generate(user())
      {:ok, conversation} = Magus.Chat.create_conversation(%{}, actor: user)
      agent_record = custom_agent(user, %{is_paused: false})

      {:ok, waiting_event} =
        Magus.Agents.create_waiting_inbox_event(
          %{
            agent_id: agent_record.id,
            event_type: :approval_response,
            urgency: :deferred,
            title: "Waiting for approval",
            source_type: :conversation,
            source_id: conversation.id,
            payload: %{"options" => ["Approve", "Reject"], "question" => "Deploy to prod?"}
          },
          actor: user
        )

      agent = build_agent(user.id, conversation.id)
      context = build_context(agent)

      signal =
        make_message_user_signal(
          "Approve: let's ship it",
          conversation.id,
          Ash.UUIDv7.generate()
        )

      InboxEventPlugin.handle_signal(signal, context)

      resolved =
        Magus.Agents.AgentInboxEvent
        |> Ash.get!(waiting_event.id, authorize?: false)

      assert resolved.status == :resolved

      new_event =
        Magus.Agents.AgentInboxEvent
        |> Ash.Query.filter(
          agent_id == ^agent_record.id and event_type == :approval_response and
            status == :pending
        )
        |> Ash.read_one!(authorize?: false)

      assert new_event.urgency == :immediate
      assert new_event.idempotency_key == "approval_response:#{waiting_event.id}"
      assert new_event.payload["chosen_option"] == "Approve"
      assert new_event.payload["response_text"] =~ "Approve:"
    end
  end

  # ============================================================================
  # Error resilience
  # ============================================================================

  describe "error resilience" do
    test "returns {:ok, :continue} even when agent state has no user_id" do
      conv_id = Ash.UUIDv7.generate()
      # Agent with nil user_id — parse will return [] since user_id is nil
      agent = %{id: "conv:#{conv_id}", state: %{user_id: nil, conversation_id: conv_id}}
      context = build_context(agent)
      signal = make_message_user_signal("hey @someone do this", conv_id, Ash.UUIDv7.generate())

      assert {:ok, :continue} = InboxEventPlugin.handle_signal(signal, context)
    end
  end
end
