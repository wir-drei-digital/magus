defmodule Magus.Agents.Tools.Conversations.ConversationToolsTest do
  @moduledoc """
  Tests for conversation history tools.

  Tests cover:
  - Tool execution with valid context
  - Tool execution with missing context
  - Error handling
  - Display name and output summarization
  - Pagination behavior
  - Search functionality
  """
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Conversations.{
    SearchConversationHistory,
    FetchConversationHistory
  }

  alias Magus.Chat

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  defp create_test_context do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

    %{
      user: user,
      conversation: conversation,
      context: %{
        user_id: user.id,
        conversation_id: conversation.id,
        folder_id: nil
      }
    }
  end

  defp create_message(conversation, user, text) do
    # Create message using the generator pattern
    # Note: This will trigger the respond Oban job, but it won't run in test mode
    generate(message(actor: user, conversation_id: conversation.id, text: text))
  end

  # ---------------------------------------------------------------------------
  # FetchConversationHistory Tests
  # ---------------------------------------------------------------------------

  describe "FetchConversationHistory" do
    test "provides display_name" do
      assert FetchConversationHistory.display_name() == "Fetching conversation history..."
    end

    test "summarizes output correctly" do
      assert FetchConversationHistory.summarize_output(%{count: 0}) == "No messages"
      assert FetchConversationHistory.summarize_output(%{count: 5}) == "Fetched 5 messages"
      assert FetchConversationHistory.summarize_output(%{error: "some error"}) == "Error"
      assert FetchConversationHistory.summarize_output(%{}) == "Completed"
    end

    test "returns empty list for new conversation" do
      %{context: context} = create_test_context()

      assert {:ok, result} = FetchConversationHistory.run(%{}, context)
      assert result.count == 0
      assert result.messages == []
    end

    test "fetches messages from conversation" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      for i <- 1..5 do
        create_message(conversation, user, "Message #{i}")
      end

      assert {:ok, result} = FetchConversationHistory.run(%{}, context)
      assert result.count == 5
      assert length(result.messages) == 5
    end

    test "respects limit parameter" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      for i <- 1..10 do
        create_message(conversation, user, "Message #{i}")
      end

      assert {:ok, result} = FetchConversationHistory.run(%{limit: 3}, context)
      assert result.count == 3
      assert length(result.messages) == 3
    end

    test "enforces maximum limit of 50" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      for i <- 1..60 do
        create_message(conversation, user, "Message #{i}")
      end

      assert {:ok, result} = FetchConversationHistory.run(%{limit: 100}, context)
      assert result.count <= 50
    end

    test "returns messages in reverse chronological order" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      for i <- 1..5 do
        create_message(conversation, user, "Message #{i}")
        :timer.sleep(10)
      end

      assert {:ok, result} = FetchConversationHistory.run(%{}, context)

      # Messages should be newest first
      texts = Enum.map(result.messages, & &1.text)
      assert hd(texts) == "Message 5"
      assert List.last(texts) == "Message 1"
    end

    test "supports pagination with before_id" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      messages =
        for i <- 1..10 do
          msg = create_message(conversation, user, "Message #{i}")
          :timer.sleep(10)
          msg
        end

      # Get the 5th message (middle of the list)
      middle_message = Enum.at(messages, 4)

      assert {:ok, result} =
               FetchConversationHistory.run(%{before_id: middle_message.id, limit: 3}, context)

      # Should return messages before the middle one
      assert result.count == 3

      # All returned messages should be older than the middle message
      for msg <- result.messages do
        assert msg.id != middle_message.id
      end
    end

    test "returns has_more indicator" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      for i <- 1..10 do
        create_message(conversation, user, "Message #{i}")
      end

      assert {:ok, result} = FetchConversationHistory.run(%{limit: 5}, context)
      assert result.has_more == true

      assert {:ok, result_all} = FetchConversationHistory.run(%{limit: 20}, context)
      assert result_all.has_more == false
    end

    test "returns error with missing context" do
      assert {:ok, result} = FetchConversationHistory.run(%{}, %{})
      assert result.error =~ "Missing required context"
    end

    test "works with string keys in context" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      string_context = %{
        "user_id" => user.id,
        "conversation_id" => conversation.id
      }

      assert {:ok, result} = FetchConversationHistory.run(%{}, string_context)
      assert result.count == 0
    end

    test "clamps limit of 0 to 1" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      create_message(conversation, user, "Test message")

      # Limit of 0 is clamped to 1 (Ash requires positive integers)
      assert {:ok, result} = FetchConversationHistory.run(%{limit: 0}, context)
      assert result.count == 1
    end

    test "handles invalid before_id gracefully" do
      %{context: context} = create_test_context()

      # Non-existent UUID should still work (just returns all messages)
      invalid_id = Ash.UUIDv7.generate()
      assert {:ok, result} = FetchConversationHistory.run(%{before_id: invalid_id}, context)
      assert result.count == 0
    end
  end

  # ---------------------------------------------------------------------------
  # SearchConversationHistory Tests
  # ---------------------------------------------------------------------------

  describe "SearchConversationHistory" do
    test "provides display_name" do
      assert SearchConversationHistory.display_name() == "Searching conversation history..."
    end

    test "summarizes output correctly" do
      assert SearchConversationHistory.summarize_output(%{count: 0}) == "No matches"
      assert SearchConversationHistory.summarize_output(%{count: 3}) == "Found 3 messages"
      assert SearchConversationHistory.summarize_output(%{error: "err"}) == "Error"
      assert SearchConversationHistory.summarize_output(%{}) == "Completed"
    end

    test "returns empty results for conversation without messages" do
      %{context: context} = create_test_context()

      assert {:ok, result} = SearchConversationHistory.run(%{query: "test"}, context)
      assert result.count == 0
      assert result.messages == []
    end

    test "finds messages matching search query" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      create_message(conversation, user, "Hello world")
      create_message(conversation, user, "Goodbye world")
      create_message(conversation, user, "Something else entirely")

      assert {:ok, result} = SearchConversationHistory.run(%{query: "world"}, context)
      assert result.count == 2
    end

    test "respects limit parameter" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      for i <- 1..10 do
        create_message(conversation, user, "Test message #{i}")
      end

      assert {:ok, result} = SearchConversationHistory.run(%{query: "Test", limit: 3}, context)
      assert result.count <= 3
    end

    test "enforces maximum limit of 50" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      for i <- 1..60 do
        create_message(conversation, user, "Searchable content #{i}")
      end

      assert {:ok, result} =
               SearchConversationHistory.run(%{query: "Searchable", limit: 100}, context)

      assert result.count <= 50
    end

    test "only searches within current conversation" do
      %{user: user, conversation: conversation1, context: context1} = create_test_context()
      %{user: user2, conversation: conversation2} = create_test_context()

      create_message(conversation1, user, "Unique phrase ABC123")
      create_message(conversation2, user2, "Unique phrase ABC123")

      assert {:ok, result} = SearchConversationHistory.run(%{query: "ABC123"}, context1)
      assert result.count == 1
    end

    test "returns error with missing context" do
      assert {:ok, result} = SearchConversationHistory.run(%{query: "test"}, %{})
      assert result.error =~ "Missing required context"
    end

    test "returns error when query is empty" do
      %{context: context} = create_test_context()

      assert {:ok, result} = SearchConversationHistory.run(%{query: ""}, context)
      assert result.error =~ "required"
    end

    test "works with string keys in context" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      string_context = %{
        "user_id" => user.id,
        "conversation_id" => conversation.id
      }

      assert {:ok, result} = SearchConversationHistory.run(%{query: "test"}, string_context)
      assert result.count == 0
    end

    test "clamps limit of 0 to 1" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      create_message(conversation, user, "Searchable test message")

      # Limit of 0 is clamped to 1 (Ash requires positive integers)
      assert {:ok, result} =
               SearchConversationHistory.run(%{query: "Searchable", limit: 0}, context)

      assert result.count == 1
    end

    test "returns formatted messages with expected fields" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      create_message(conversation, user, "Test message for format check")

      assert {:ok, result} = SearchConversationHistory.run(%{query: "format"}, context)
      assert result.count == 1

      [message] = result.messages
      assert Map.has_key?(message, :id)
      assert Map.has_key?(message, :role)
      assert Map.has_key?(message, :text)
      assert Map.has_key?(message, :created_at)
    end
  end

  # ---------------------------------------------------------------------------
  # Integration Tests
  # ---------------------------------------------------------------------------

  describe "tool integration" do
    test "fetch and search work together" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      # Create some messages
      create_message(conversation, user, "First message about cats")
      create_message(conversation, user, "Second message about dogs")
      create_message(conversation, user, "Third message about cats again")

      # Fetch all
      assert {:ok, fetch_result} = FetchConversationHistory.run(%{}, context)
      assert fetch_result.count == 3

      # Search for specific topic
      assert {:ok, search_result} = SearchConversationHistory.run(%{query: "cats"}, context)
      assert search_result.count == 2
    end

    test "pagination flows correctly" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      # Create ordered messages
      for i <- 1..15 do
        create_message(conversation, user, "Paginated message #{i}")
        :timer.sleep(10)
      end

      # First page
      assert {:ok, page1} = FetchConversationHistory.run(%{limit: 5}, context)
      assert page1.count == 5
      assert page1.has_more == true

      # Get last message from first page to use as cursor
      last_msg = List.last(page1.messages)

      # Second page
      assert {:ok, page2} =
               FetchConversationHistory.run(%{limit: 5, before_id: last_msg.id}, context)

      assert page2.count == 5
      assert page2.has_more == true

      # Verify no overlap between pages
      page1_ids = Enum.map(page1.messages, & &1.id) |> MapSet.new()
      page2_ids = Enum.map(page2.messages, & &1.id) |> MapSet.new()
      assert MapSet.disjoint?(page1_ids, page2_ids)
    end
  end
end
