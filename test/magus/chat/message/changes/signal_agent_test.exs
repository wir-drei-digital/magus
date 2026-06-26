defmodule Magus.Chat.Message.Changes.SignalAgentTest do
  @moduledoc """
  Integration tests for the SignalAgent change.

  These tests verify that creating a user message correctly triggers
  signal-native agent dispatch without errors.

  This test suite exists specifically to catch field access errors like:
  - Using `message.user_id` instead of `message.created_by_id`
  - Missing relationship loads
  - Incorrect field mappings
  """
  use Magus.ResourceCase, async: false

  alias Magus.Chat

  describe "user message creation triggers agent dispatch" do
    test "creates user message without KeyError on field access" do
      # This test specifically catches the bug where SignalAgent
      # tried to access message.user_id instead of message.created_by_id
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{title: "Test"}, actor: user)

      # Creating a user message should trigger SignalAgent dispatch
      # This should NOT raise KeyError for missing fields
      result =
        Chat.create_message(
          %{
            conversation_id: conversation.id,
            text: "Hello, this is a test message"
          },
          actor: user
        )

      # Message creation should succeed
      assert {:ok, message} = result
      assert message.text == "Hello, this is a test message"
      assert message.role == :user
      assert message.created_by_id == user.id
      assert message.conversation_id == conversation.id
    end

    test "handles message with mode specified" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{chat_mode: :search}, actor: user)

      result =
        Chat.create_message(
          %{
            conversation_id: conversation.id,
            text: "Search for something",
            mode: :search
          },
          actor: user
        )

      assert {:ok, message} = result
      assert message.mode == :search
    end

    test "handles message with selected_model_id" do
      user = generate(user())
      model = generate(model(key: "test/model"))
      {:ok, conversation} = Chat.create_conversation(%{title: "Test"}, actor: user)

      result =
        Chat.create_message(
          %{
            conversation_id: conversation.id,
            text: "Test with model",
            selected_model_id: model.id
          },
          actor: user
        )

      assert {:ok, message} = result
      assert message.selected_model_id == model.id
    end

    test "handles message with attachments" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{title: "Test"}, actor: user)

      result =
        Chat.create_message(
          %{
            conversation_id: conversation.id,
            text: "Message with attachment"
          },
          actor: user
        )

      assert {:ok, message} = result
      # Attachments default to empty list
      assert message.attachments == []
    end
  end

  describe "message struct field access" do
    test "message has created_by_id (not user_id)" do
      # This test documents that Message uses created_by_id, not user_id
      # to prevent future regressions
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{title: "Test"}, actor: user)

      {:ok, message} =
        Chat.create_message(
          %{conversation_id: conversation.id, text: "Test"},
          actor: user
        )

      # Message DOES have created_by_id
      assert Map.has_key?(message, :created_by_id)
      assert message.created_by_id == user.id

      # Message does NOT have user_id field
      refute Map.has_key?(message, :user_id)
    end

    test "message has conversation_id" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{title: "Test"}, actor: user)

      {:ok, message} =
        Chat.create_message(
          %{conversation_id: conversation.id, text: "Test"},
          actor: user
        )

      assert Map.has_key?(message, :conversation_id)
      assert message.conversation_id == conversation.id
    end

    test "message can load created_by relationship" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{title: "Test"}, actor: user)

      {:ok, message} =
        Chat.create_message(
          %{conversation_id: conversation.id, text: "Test"},
          actor: user
        )

      # Load the created_by relationship
      {:ok, loaded} = Chat.get_message(message.id, load: [:created_by], actor: user)

      assert loaded.created_by.id == user.id
    end
  end

  describe "new conversation flow" do
    test "first message in new conversation triggers agent correctly" do
      # This simulates the exact flow from the UI:
      # 1. User starts a new chat
      # 2. Types a message
      # 3. Message is created, triggering SignalAgent
      user = generate(user())

      # Create conversation (simulating ChatLive.handle_send_message)
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      # Send first message
      {:ok, message} =
        Chat.create_message(
          %{
            conversation_id: conversation.id,
            text: "Hello"
          },
          actor: user
        )

      # Message should be created successfully
      assert message.role == :user
      assert message.text == "Hello"
      assert message.created_by_id == user.id

      # The SignalAgent should have run without errors
      # (if it failed, we'd get a KeyError or similar)
    end

    test "message with all optional fields set" do
      user = generate(user())
      model = generate(model(key: "test/full-model"))
      {:ok, conversation} = Chat.create_conversation(%{chat_mode: :reasoning}, actor: user)

      # Create message with all possible fields
      {:ok, message} =
        Chat.create_message(
          %{
            conversation_id: conversation.id,
            text: "Full message test",
            mode: :reasoning,
            selected_model_id: model.id,
            metadata: %{"source" => "test"}
          },
          actor: user
        )

      assert message.mode == :reasoning
      assert message.selected_model_id == model.id
      assert message.metadata == %{"source" => "test"}
      assert message.created_by_id == user.id
    end
  end
end
