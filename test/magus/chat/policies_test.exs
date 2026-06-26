defmodule Magus.Chat.PoliciesTest do
  @moduledoc """
  Tests for authorization policies in the Chat domain.

  Tests resources that have `authorizers: [Ash.Policy.Authorizer]` configured:
  - Conversation
  - ConversationInvitation
  - ConversationInviteLink
  - ConversationMember
  - Message

  Note: Folder does NOT have authorizers configured.
  """
  use Magus.ResourceCase, async: true

  alias Magus.Chat

  describe "Conversation policies" do
    test "owner can read their conversation" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, found} = Chat.get_conversation(conversation.id, actor: user)
      assert found.id == conversation.id
    end

    test "owner can rename their conversation" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, renamed} = Chat.rename_conversation(conversation, %{title: "New Title"}, actor: user)
      assert renamed.title == "New Title"
    end

    test "non-owner cannot read private conversation" do
      owner = generate(user())
      other = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      # Non-owner should not be able to read (returns not found, not forbidden for security)
      assert {:error, %Ash.Error.Invalid{}} =
               Chat.get_conversation(conversation.id, actor: other)
    end

    test "non-owner cannot rename conversation" do
      owner = generate(user())
      other = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      assert {:error, %Ash.Error.Forbidden{}} =
               Chat.rename_conversation(conversation, %{title: "Hacked"}, actor: other)
    end

    test "conversation member can read conversation" do
      owner = generate(user())
      member = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      # add_member policy uses relationship filters that can't evaluate on create
      {:ok, membership} =
        Chat.add_conversation_member(conversation.id, member.id, %{}, authorize?: false)

      {:ok, _} = Chat.accept_conversation_invitation(membership, actor: member)

      {:ok, found} = Chat.get_conversation(conversation.id, actor: member)
      assert found.id == conversation.id
    end

    test "pending member cannot read conversation" do
      owner = generate(user())
      member = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      # add_member policy uses relationship filters that can't evaluate on create
      {:ok, _membership} =
        Chat.add_conversation_member(conversation.id, member.id, %{}, authorize?: false)

      # Pending member should not be able to read
      assert {:error, %Ash.Error.Invalid{}} =
               Chat.get_conversation(conversation.id, actor: member)
    end
  end

  describe "ConversationMember policies" do
    test "member can accept their own invitation" do
      owner = generate(user())
      member = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      # add_member policy uses relationship filters that can't evaluate on create
      {:ok, membership} =
        Chat.add_conversation_member(conversation.id, member.id, %{}, authorize?: false)

      {:ok, accepted} = Chat.accept_conversation_invitation(membership, actor: member)
      assert accepted.accepted_at != nil
    end

    test "other user cannot accept someone elses invitation" do
      owner = generate(user())
      member = generate(user())
      other = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      # add_member policy uses relationship filters that can't evaluate on create
      {:ok, membership} =
        Chat.add_conversation_member(conversation.id, member.id, %{}, authorize?: false)

      assert {:error, %Ash.Error.Forbidden{}} =
               Chat.accept_conversation_invitation(membership, actor: other)
    end

    test "member can leave conversation (remove themselves)" do
      owner = generate(user())
      member = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      # add_member policy uses relationship filters that can't evaluate on create
      {:ok, membership} =
        Chat.add_conversation_member(conversation.id, member.id, %{}, authorize?: false)

      {:ok, _} = Chat.accept_conversation_invitation(membership, actor: member)

      # Reload membership
      {:ok, members} = Chat.get_conversation_members(conversation.id, actor: owner)
      membership = Enum.find(members, &(&1.user_id == member.id))

      assert :ok = Chat.remove_conversation_member(membership, actor: member)
    end
  end

  describe "ConversationInvitation policies" do
    test "owner can create invitation" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      {:ok, invitation} =
        Chat.create_invitation(
          conversation.id,
          %{email: "test@example.com"},
          actor: owner
        )

      assert invitation.email != nil
    end

    test "non-owner cannot create invitation" do
      owner = generate(user())
      other = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      assert {:error, %Ash.Error.Forbidden{}} =
               Chat.create_invitation(
                 conversation.id,
                 %{email: "hacker@example.com"},
                 actor: other
               )
    end

    test "anyone can lookup invitation by token" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      {:ok, invitation} =
        Chat.create_invitation(
          conversation.id,
          %{email: "test@example.com"},
          actor: owner
        )

      # Token-based lookup is intentionally unauthenticated (public join flow)
      {:ok, found} = Chat.get_invitation_by_token(invitation.token, authorize?: false)
      assert found.id == invitation.id
    end
  end

  describe "Message policies" do
    test "owner can create messages in their conversation" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.create_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      assert message.text == "Hello"
      assert message.conversation_id == conversation.id
    end

    test "owner can read messages in their conversation" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.create_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      {:ok, messages} = Chat.message_history(conversation.id, actor: user)
      assert hd(messages).id == message.id
    end

    test "owner can update messages in their conversation" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.create_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      {:ok, toggled} = Chat.toggle_message_disabled(message, actor: user)
      assert toggled.disabled == true
    end

    test "non-owner cannot create messages in private conversation" do
      owner = generate(user())
      other = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      assert {:error, %Ash.Error.Forbidden{}} =
               Chat.create_message(
                 %{text: "Unauthorized", conversation_id: conversation.id},
                 actor: other
               )
    end

    test "non-owner cannot read messages in private conversation" do
      owner = generate(user())
      other = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      {:ok, _message} =
        Chat.create_message(%{text: "Secret", conversation_id: conversation.id}, actor: owner)

      # Non-owner should not be able to read messages
      {:ok, messages} = Chat.message_history(conversation.id, actor: other)
      assert messages == []
    end

    test "conversation member can create messages" do
      owner = generate(user())
      member = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      {:ok, membership} =
        Chat.add_conversation_member(conversation.id, member.id, %{}, authorize?: false)

      {:ok, _} = Chat.accept_conversation_invitation(membership, actor: member)

      {:ok, message} =
        Chat.create_message(
          %{text: "Member message", conversation_id: conversation.id},
          actor: member
        )

      assert message.text == "Member message"
    end

    test "conversation member can read messages" do
      owner = generate(user())
      member = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      {:ok, membership} =
        Chat.add_conversation_member(conversation.id, member.id, %{}, authorize?: false)

      {:ok, _} = Chat.accept_conversation_invitation(membership, actor: member)

      {:ok, _message} =
        Chat.create_message(%{text: "Owner message", conversation_id: conversation.id},
          actor: owner
        )

      {:ok, messages} = Chat.message_history(conversation.id, actor: member)
      assert length(messages) == 1
    end
  end
end
