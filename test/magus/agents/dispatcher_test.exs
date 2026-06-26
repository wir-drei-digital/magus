defmodule Magus.Agents.DispatcherTest do
  @moduledoc """
  Integration tests for the signal-native message dispatcher.
  """

  use Magus.ResourceCase, async: false

  alias Magus.Agents.Dispatcher
  alias Magus.Chat

  describe "dispatch_message/3" do
    @tag :integration
    test "dispatches a user message to the conversation agent" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{title: "Test"}, actor: user)

      message = %{
        id: Ash.UUID.generate(),
        conversation_id: conversation.id,
        created_by_id: user.id,
        text: "Hello agent",
        attachments: [],
        mode: nil,
        selected_model_id: nil,
        metadata: %{}
      }

      case Dispatcher.dispatch_message(message, conversation.id, conversation.user_id) do
        {:ok, result} ->
          assert result.signaled == true
          assert result.signal_type == "message.user"
          assert result.agent_id == "conv:#{conversation.id}"

        {:error, reason} ->
          # Some test environments do not start conversation agent registries.
          # The Dispatcher wraps this as {:registry_unavailable, message}.
          assert match?({:registry_unavailable, _}, reason),
                 "Expected {:registry_unavailable, _}, got: #{inspect(reason)}"
      end
    end

    test "returns error for non-existent conversation" do
      user = generate(user())

      fake_message = %{
        id: Ash.UUID.generate(),
        text: "Hello",
        conversation_id: Ash.UUID.generate(),
        created_by_id: user.id,
        attachments: [],
        mode: :chat,
        selected_model_id: nil,
        metadata: %{}
      }

      assert {:error, _reason} =
               Dispatcher.dispatch_message(
                 fake_message,
                 fake_message.conversation_id,
                 user.id
               )
    end

    test "refuses to start a turn while compaction is :running" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{title: "Compaction lock"}, actor: user)

      {:ok, cw} = Chat.get_or_create_context_window(conversation.id, actor: user)

      {:ok, _} =
        Chat.mark_context_compacting(cw, %{}, actor: %Magus.Agents.Support.AiAgent{})

      message = %{
        id: Ash.UUID.generate(),
        conversation_id: conversation.id,
        created_by_id: user.id,
        text: "Hello agent",
        attachments: [],
        mode: nil,
        selected_model_id: nil,
        metadata: %{}
      }

      assert {:error, {:compaction_in_progress, conversation_id}} =
               Dispatcher.dispatch_message(message, conversation.id, conversation.user_id)

      assert conversation_id == conversation.id
    end

    test "proceeds past the compaction gate when status is :idle" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{title: "Idle window"}, actor: user)

      # An :idle window must NOT block the turn — get past the gate (the turn may
      # then fail later in test envs without a started agent registry, but never
      # with the compaction-lock error).
      {:ok, _cw} = Chat.get_or_create_context_window(conversation.id, actor: user)

      message = %{
        id: Ash.UUID.generate(),
        conversation_id: conversation.id,
        created_by_id: user.id,
        text: "Hello agent",
        attachments: [],
        mode: nil,
        selected_model_id: nil,
        metadata: %{}
      }

      result = Dispatcher.dispatch_message(message, conversation.id, conversation.user_id)
      refute match?({:error, {:compaction_in_progress, _}}, result)
    end

    test "proceeds past the compaction gate when there is no context window row" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{title: "No window"}, actor: user)

      message = %{
        id: Ash.UUID.generate(),
        conversation_id: conversation.id,
        created_by_id: user.id,
        text: "Hello agent",
        attachments: [],
        mode: nil,
        selected_model_id: nil,
        metadata: %{}
      }

      result = Dispatcher.dispatch_message(message, conversation.id, conversation.user_id)
      refute match?({:error, {:compaction_in_progress, _}}, result)
    end
  end

  describe "build_signal_data/3" do
    test "builds message facts for agent-side preflight context assembly" do
      user = generate(user())

      {:ok, conversation} =
        Chat.create_conversation(%{title: "Runtime override test"}, actor: user)

      message = %{
        id: Ash.UUID.generate(),
        conversation_id: conversation.id,
        created_by_id: user.id,
        text: "Hello",
        attachments: [],
        mode: nil,
        selected_model_id: nil,
        metadata: %{}
      }

      routed = %{model_keys: %{chat: "openrouter:test-model"}, routing_reason: :manual}
      signal_data = Dispatcher.build_signal_data(message, conversation, routed)

      assert signal_data.message_id == to_string(message.id)
      assert signal_data.text == "Hello"
      assert signal_data.model_keys == %{chat: "openrouter:test-model"}
      assert signal_data.routing_reason == :manual
      assert signal_data.conversation_context.id == conversation.id
    end

    test "conversation_context includes preloaded relationships for Preflight reuse" do
      user = generate(user())

      {:ok, conversation} =
        Chat.create_conversation(%{title: "Preload verification"}, actor: user)

      # Load conversation the same way the Dispatcher does internally, with
      # all the relationships that Preflight needs for context assembly.
      {:ok, loaded_conversation} =
        Chat.get_conversation(conversation.id,
          load: [
            :active_system_prompt,
            :selected_model,
            :selected_image_model,
            :selected_video_model,
            custom_agent: [:model, :image_model, :video_model],
            user: [:selected_model, :selected_image_model, :selected_video_model]
          ],
          authorize?: false
        )

      message = %{
        id: Ash.UUID.generate(),
        conversation_id: conversation.id,
        created_by_id: user.id,
        text: "Hello",
        attachments: [],
        mode: nil,
        selected_model_id: nil,
        metadata: %{}
      }

      routed = %{model_keys: %{chat: "openrouter:test-model"}, routing_reason: :manual}
      signal_data = Dispatcher.build_signal_data(message, loaded_conversation, routed)

      ctx = signal_data.conversation_context
      assert ctx.id == conversation.id

      # Verify that key relationships are loaded (not %Ash.NotLoaded{}),
      # so Preflight can use them without a redundant DB round-trip.
      refute match?(%Ash.NotLoaded{}, ctx.user)
      assert %{id: _} = ctx.user
      refute match?(%Ash.NotLoaded{}, ctx.active_system_prompt)
    end

    test "normalizes non-list attachments to empty list" do
      user = generate(user())

      {:ok, conversation} =
        Chat.create_conversation(%{title: "Attachment normalization"}, actor: user)

      message = %{
        id: Ash.UUID.generate(),
        conversation_id: conversation.id,
        created_by_id: user.id,
        text: "Hello",
        attachments: %{unexpected: true},
        mode: nil,
        selected_model_id: nil,
        metadata: %{}
      }

      routed = %{model_keys: %{chat: "openrouter:test-model"}, routing_reason: :manual}
      signal_data = Dispatcher.build_signal_data(message, conversation, routed)

      assert signal_data.attachments == []
    end
  end
end
