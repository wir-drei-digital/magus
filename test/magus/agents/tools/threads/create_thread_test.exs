defmodule Magus.Agents.Tools.Threads.CreateThreadTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Threads.CreateThread

  describe "display_name/0 and summarize_output/1" do
    test "provides display name" do
      assert CreateThread.display_name() == "Creating thread..."
    end

    test "summarizes output with title" do
      assert CreateThread.summarize_output(%{thread_conversation_id: "abc", title: "Deep dive"}) ==
               "Created thread: Deep dive"
    end

    test "summarizes output without title" do
      assert CreateThread.summarize_output(%{thread_conversation_id: "abc", title: nil}) ==
               "Created thread: abc"
    end

    test "summarizes error output" do
      assert CreateThread.summarize_output(%{error: "Not found"}) == "Error: Not found"
    end
  end

  describe "run/2" do
    test "creates a thread and sends initial message" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      message =
        generate(message(actor: user, conversation_id: conversation.id, text: "Original message"))

      params = %{
        "message_id" => message.id,
        "initial_message" => "Let me explore this in detail",
        "title" => "Deep dive"
      }

      context = %{
        conversation_id: conversation.id,
        user_id: user.id,
        user: user
      }

      assert {:ok, result} = CreateThread.run(params, context)
      assert result.thread_conversation_id
      assert result.title == "Deep dive"

      # Load the thread and verify its properties
      {:ok, thread} =
        Chat.get_conversation(result.thread_conversation_id, actor: user)

      assert thread.is_thread == true
      assert thread.parent_conversation_id == conversation.id
      assert thread.branched_at_message_id == message.id
      assert thread.title == "Deep dive"
    end

    test "creates a thread without a title" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      message =
        generate(message(actor: user, conversation_id: conversation.id, text: "Original message"))

      params = %{
        "message_id" => message.id,
        "initial_message" => "Let me explore this in detail"
      }

      context = %{
        conversation_id: conversation.id,
        user_id: user.id,
        user: user
      }

      assert {:ok, result} = CreateThread.run(params, context)
      assert result.thread_conversation_id
      refute result.title
    end

    test "returns error when message not found" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      params = %{
        "message_id" => Ash.UUID.generate(),
        "initial_message" => "Let me explore this",
        "title" => "Deep dive"
      }

      context = %{
        conversation_id: conversation.id,
        user_id: user.id,
        user: user
      }

      assert {:ok, result} = CreateThread.run(params, context)
      assert result.error
    end

    test "returns error when context is missing" do
      params = %{
        "message_id" => Ash.UUID.generate(),
        "initial_message" => "Test"
      }

      assert {:ok, result} = CreateThread.run(params, %{})
      assert result.error =~ "Missing required context"
    end
  end
end
