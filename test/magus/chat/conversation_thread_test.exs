defmodule Magus.Chat.ConversationThreadTest do
  use Magus.ResourceCase, async: true

  alias Magus.Chat

  describe "create_thread/1" do
    test "creates a thread branching from a message" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      message =
        generate(message(actor: user, conversation_id: conversation.id, text: "Branch here"))

      {:ok, thread} =
        Chat.create_thread(
          %{
            parent_conversation_id: conversation.id,
            branched_at_message_id: message.id
          },
          actor: user
        )

      assert thread.is_thread == true
      assert thread.parent_conversation_id == conversation.id
      assert thread.branched_at_message_id == message.id
      assert thread.branched_at == message.inserted_at
      assert thread.user_id == user.id
      assert thread.is_task_conversation == false
    end

    test "copies model and settings from parent conversation" do
      user = generate(user())
      model = generate(model())

      {:ok, conversation} =
        Chat.create_conversation(
          %{chat_mode: :reasoning, selected_model_id: model.id},
          actor: user
        )

      message = generate(message(actor: user, conversation_id: conversation.id))

      {:ok, thread} =
        Chat.create_thread(
          %{
            parent_conversation_id: conversation.id,
            branched_at_message_id: message.id
          },
          actor: user
        )

      assert thread.chat_mode == :reasoning
      assert thread.selected_model_id == model.id
    end

    test "copies members from parent multiplayer conversation" do
      owner = generate(user())
      member_user = generate(user())

      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, conversation} = Chat.enable_multiplayer(conversation, actor: owner)

      {:ok, member_record} =
        Chat.add_conversation_member(conversation.id, member_user.id,
          actor: %Magus.Agents.Support.AiAgent{}
        )

      {:ok, _} = Chat.accept_conversation_invitation(member_record, actor: member_user)

      message = generate(message(actor: owner, conversation_id: conversation.id))

      {:ok, thread} =
        Chat.create_thread(
          %{
            parent_conversation_id: conversation.id,
            branched_at_message_id: message.id
          },
          actor: owner
        )

      assert thread.is_multiplayer == true

      {:ok, thread_members} =
        Chat.get_accepted_members(thread.id, actor: owner)

      member_user_ids = Enum.map(thread_members, & &1.user_id) |> Enum.sort()
      expected_user_ids = Enum.sort([owner.id, member_user.id])
      assert member_user_ids == expected_user_ids
    end

    test "rejects nested threads" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
      message = generate(message(actor: user, conversation_id: conversation.id))

      {:ok, thread} =
        Chat.create_thread(
          %{
            parent_conversation_id: conversation.id,
            branched_at_message_id: message.id
          },
          actor: user
        )

      thread_message = generate(message(actor: user, conversation_id: thread.id))

      {:error, _} =
        Chat.create_thread(
          %{
            parent_conversation_id: thread.id,
            branched_at_message_id: thread_message.id
          },
          actor: user
        )
    end
  end

  describe "threads excluded from listings" do
    test "threads are excluded from my_conversations" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{title: "Parent"}, actor: user)
      message = generate(message(actor: user, conversation_id: conversation.id))

      {:ok, _thread} =
        Chat.create_thread(
          %{
            parent_conversation_id: conversation.id,
            branched_at_message_id: message.id
          },
          actor: user
        )

      {:ok, conversations} = Chat.my_conversations(actor: user)
      conversation_ids = Enum.map(conversations, & &1.id)

      assert conversation.id in conversation_ids
      refute Enum.any?(conversations, & &1.is_thread)
    end
  end

  describe "threads_for_conversation/1" do
    test "returns threads for a given conversation" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
      msg1 = generate(message(actor: user, conversation_id: conversation.id))
      msg2 = generate(message(actor: user, conversation_id: conversation.id))

      {:ok, thread1} =
        Chat.create_thread(
          %{
            parent_conversation_id: conversation.id,
            branched_at_message_id: msg1.id
          },
          actor: user
        )

      {:ok, thread2} =
        Chat.create_thread(
          %{
            parent_conversation_id: conversation.id,
            branched_at_message_id: msg2.id
          },
          actor: user
        )

      {:ok, threads} = Chat.threads_for_conversation(conversation.id, actor: user)
      thread_ids = Enum.map(threads, & &1.id)

      assert thread1.id in thread_ids
      assert thread2.id in thread_ids
      assert length(threads) == 2
    end
  end

  describe "create_thread validations" do
    test "rejects thread when message does not belong to parent conversation" do
      user = generate(user())
      conversation1 = generate(conversation(actor: user))
      conversation2 = generate(conversation(actor: user))
      message_in_conv2 = generate(message(conversation_id: conversation2.id, actor: user))

      assert {:error, _} =
               Chat.create_thread(
                 %{
                   parent_conversation_id: conversation1.id,
                   branched_at_message_id: message_in_conv2.id
                 },
                 actor: user
               )
    end

    test "threads_for_conversations returns threads across multiple conversations" do
      user = generate(user())
      conv1 = generate(conversation(actor: user))
      conv2 = generate(conversation(actor: user))
      msg1 = generate(message(conversation_id: conv1.id, actor: user))
      msg2 = generate(message(conversation_id: conv2.id, actor: user))

      {:ok, thread1} =
        Chat.create_thread(
          %{parent_conversation_id: conv1.id, branched_at_message_id: msg1.id},
          actor: user
        )

      {:ok, thread2} =
        Chat.create_thread(
          %{parent_conversation_id: conv2.id, branched_at_message_id: msg2.id},
          actor: user
        )

      {:ok, threads} = Chat.threads_for_conversations([conv1.id, conv2.id], actor: user)
      thread_ids = Enum.map(threads, & &1.id)

      assert thread1.id in thread_ids
      assert thread2.id in thread_ids
    end
  end
end
