defmodule Magus.Chat.ConversationSoftDeleteTest do
  use Magus.ResourceCase, async: true

  alias Magus.Chat

  describe "soft_delete/1" do
    test "sets deleted_at on the conversation" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{title: "To Delete"}, actor: user)

      {:ok, deleted} = Chat.soft_delete_conversation(conversation, actor: user)

      assert deleted.deleted_at != nil
    end

    test "soft-deleted conversation is hidden from my_conversations" do
      user = generate(user())
      {:ok, conv1} = Chat.create_conversation(%{title: "Keep"}, actor: user)
      {:ok, conv2} = Chat.create_conversation(%{title: "Delete"}, actor: user)

      Chat.soft_delete_conversation!(conv2, actor: user)

      conversations = Chat.my_conversations!(actor: user)
      ids = Enum.map(conversations, & &1.id)
      assert conv1.id in ids
      refute conv2.id in ids
    end

    test "soft-deleted conversation is hidden from unfiled_conversations" do
      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{title: "Delete Me"}, actor: user)

      Chat.soft_delete_conversation!(conv, actor: user)

      conversations = Chat.unfiled_conversations!(actor: user)
      ids = Enum.map(conversations, & &1.id)
      refute conv.id in ids
    end

    test "soft-deleted conversation appears in trashed" do
      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{title: "Trashed"}, actor: user)

      Chat.soft_delete_conversation!(conv, actor: user)

      trashed = Chat.trashed_conversations!(actor: user)
      ids = Enum.map(trashed, & &1.id)
      assert conv.id in ids
    end

    test "non-deleted conversations do not appear in trashed" do
      user = generate(user())
      {:ok, _conv} = Chat.create_conversation(%{title: "Active"}, actor: user)

      trashed = Chat.trashed_conversations!(actor: user)
      assert trashed == []
    end
  end

  describe "restore/1" do
    test "clears deleted_at and makes conversation visible again" do
      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{title: "Restore Me"}, actor: user)

      {:ok, deleted} = Chat.soft_delete_conversation(conv, actor: user)
      assert deleted.deleted_at != nil

      {:ok, restored} = Chat.restore_conversation(deleted, actor: user)
      assert restored.deleted_at == nil

      conversations = Chat.my_conversations!(actor: user)
      ids = Enum.map(conversations, & &1.id)
      assert conv.id in ids

      trashed = Chat.trashed_conversations!(actor: user)
      assert trashed == []
    end
  end

  describe "delete_full_conversation/1 (hard delete)" do
    test "permanently removes a soft-deleted conversation" do
      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{title: "Permanent Delete"}, actor: user)

      {:ok, deleted} = Chat.soft_delete_conversation(conv, actor: user)

      assert :ok = Chat.delete_full_conversation(deleted, actor: user)

      # Gone from both lists
      assert Chat.my_conversations!(actor: user) == []
      assert Chat.trashed_conversations!(actor: user) == []
    end

    test "cleans up related messages" do
      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{title: "With Messages"}, actor: user)

      _msg = generate(message(actor: user, conversation_id: conv.id, text: "Hello"))

      assert :ok = Chat.delete_full_conversation(conv, actor: user)

      messages = Chat.message_history!(conv.id, actor: user)
      assert messages == []
    end
  end

  describe "trashed_for_cleanup" do
    test "returns conversations deleted more than 30 days ago" do
      require Ash.Query

      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{title: "Old Trash"}, actor: user)

      # Soft delete and manually backdate deleted_at to 31 days ago
      Chat.soft_delete_conversation!(conv, actor: user)

      old_date = DateTime.add(DateTime.utc_now(), -31, :day)
      {:ok, conv_uuid} = Ecto.UUID.dump(conv.id)

      import Ecto.Query

      Magus.Repo.update_all(
        from(c in "conversations", where: c.id == ^conv_uuid),
        set: [deleted_at: old_date]
      )

      cleanup_candidates =
        Magus.Chat.Conversation
        |> Ash.Query.for_read(:trashed_for_cleanup)
        |> Ash.read!(authorize?: false)

      ids = Enum.map(cleanup_candidates, & &1.id)
      assert conv.id in ids
    end

    test "does not return recently deleted conversations" do
      require Ash.Query

      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{title: "Recent Trash"}, actor: user)

      Chat.soft_delete_conversation!(conv, actor: user)

      cleanup_candidates =
        Magus.Chat.Conversation
        |> Ash.Query.for_read(:trashed_for_cleanup)
        |> Ash.read!(authorize?: false)

      ids = Enum.map(cleanup_candidates, & &1.id)
      refute conv.id in ids
    end
  end
end
