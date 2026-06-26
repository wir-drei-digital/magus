defmodule Magus.Chat.ConversationMemberTest do
  @moduledoc """
  Tests for ConversationMember resource.

  Tests membership management for multiplayer conversations including:
  - Adding members with different roles
  - Accepting invitations
  - Changing roles
  - Muting/unmuting

  Note: Many member operations use `authorize?: false` because the add_member
  policy uses relationship filters that can't be evaluated on create.
  Authorization is tested separately in policies_test.exs.
  """
  use Magus.ResourceCase, async: true
  use Oban.Testing, repo: Magus.Repo

  alias Magus.Chat

  describe "add_owner/2" do
    test "adds user as owner with auto-accepted status" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      other_user = generate(user())
      # add_member policy uses relationship filters that can't evaluate on create
      {:ok, member} =
        Chat.add_conversation_owner(conversation.id, other_user.id, authorize?: false)

      assert member.role == :owner
      assert member.accepted_at != nil
      assert member.user_id == other_user.id
      assert member.conversation_id == conversation.id
    end
  end

  describe "add_member/2" do
    test "adds member to conversation with default role" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      member_user = generate(user())

      {:ok, member} =
        Chat.add_conversation_member(
          conversation.id,
          member_user.id,
          %{invited_by_id: owner.id},
          authorize?: false
        )

      assert member.role == :member
      assert member.user_id == member_user.id
      assert member.invited_at != nil
      assert member.accepted_at == nil
      assert member.invited_by_id == owner.id
    end

    test "adds member with specific role" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      observer_user = generate(user())

      {:ok, member} =
        Chat.add_conversation_member(
          conversation.id,
          observer_user.id,
          %{role: :observer},
          authorize?: false
        )

      assert member.role == :observer
    end

    test "adds member with observer role" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      observer_user = generate(user())

      {:ok, member} =
        Chat.add_conversation_member(
          conversation.id,
          observer_user.id,
          %{role: :observer},
          authorize?: false
        )

      assert member.role == :observer
    end

    test "prevents duplicate membership" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      member_user = generate(user())

      {:ok, _} =
        Chat.add_conversation_member(conversation.id, member_user.id, %{}, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               Chat.add_conversation_member(
                 conversation.id,
                 member_user.id,
                 %{},
                 authorize?: false
               )
    end
  end

  describe "accept_invitation/1" do
    test "sets accepted_at timestamp" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      member_user = generate(user())

      {:ok, member} =
        Chat.add_conversation_member(conversation.id, member_user.id, %{}, authorize?: false)

      assert member.accepted_at == nil

      {:ok, accepted} = Chat.accept_conversation_invitation(member, actor: member_user)

      assert accepted.accepted_at != nil
    end

    test "only invited user can accept" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      member_user = generate(user())
      other_user = generate(user())

      {:ok, member} =
        Chat.add_conversation_member(conversation.id, member_user.id, %{}, authorize?: false)

      assert {:error, %Ash.Error.Forbidden{}} =
               Chat.accept_conversation_invitation(member, actor: other_user)
    end
  end

  describe "change_role/2" do
    test "changes member role" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      member_user = generate(user())

      # add_member policy uses relationship filters that can't evaluate on create
      {:ok, member} =
        Chat.add_conversation_member(conversation.id, member_user.id, %{}, authorize?: false)

      {:ok, updated} = Chat.change_member_role(member, %{role: :observer}, actor: owner)

      assert updated.role == :observer
    end

    test "can change to all valid roles" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      member_user = generate(user())

      # add_member policy uses relationship filters that can't evaluate on create
      {:ok, member} =
        Chat.add_conversation_member(conversation.id, member_user.id, %{}, authorize?: false)

      for role <- [:observer, :member, :owner] do
        {:ok, updated} = Chat.change_member_role(member, %{role: role}, actor: owner)
        assert updated.role == role
      end
    end
  end

  describe "mute/unmute" do
    test "mutes member" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      member_user = generate(user())

      # add_member policy uses relationship filters that can't evaluate on create
      {:ok, member} =
        Chat.add_conversation_member(conversation.id, member_user.id, %{}, authorize?: false)

      assert member.is_muted == false

      {:ok, muted} = Chat.mute_member(member, actor: owner)

      assert muted.is_muted == true
    end

    test "unmutes member" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      member_user = generate(user())

      # add_member policy uses relationship filters that can't evaluate on create
      {:ok, member} =
        Chat.add_conversation_member(conversation.id, member_user.id, %{}, authorize?: false)

      {:ok, muted} = Chat.mute_member(member, actor: owner)

      {:ok, unmuted} = Chat.unmute_member(muted, actor: owner)

      assert unmuted.is_muted == false
    end
  end

  describe "for_conversation/1" do
    test "returns all members for conversation" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      member1 = generate(user())
      member2 = generate(user())

      # add_member policy uses relationship filters that can't evaluate on create
      {:ok, _} =
        Chat.add_conversation_member(conversation.id, member1.id, %{}, authorize?: false)

      {:ok, _} =
        Chat.add_conversation_member(conversation.id, member2.id, %{}, authorize?: false)

      {:ok, members} = Chat.get_conversation_members(conversation.id, actor: owner)

      # Owner + 2 members = 3
      assert length(members) == 3
    end
  end

  describe "accepted_for_conversation/1" do
    test "returns only accepted members" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      member1 = generate(user())
      member2 = generate(user())

      # add_member policy uses relationship filters that can't evaluate on create
      {:ok, m1} =
        Chat.add_conversation_member(conversation.id, member1.id, %{}, authorize?: false)

      {:ok, _m2} =
        Chat.add_conversation_member(conversation.id, member2.id, %{}, authorize?: false)

      # Accept one invitation
      {:ok, _} = Chat.accept_conversation_invitation(m1, actor: member1)

      {:ok, accepted} = Chat.get_accepted_members(conversation.id, actor: owner)

      # Owner (auto-accepted) + member1 (accepted) = 2
      assert length(accepted) == 2
    end
  end

  describe "my_memberships/0" do
    test "returns user's accepted memberships" do
      owner = generate(user())
      {:ok, conv1} = Chat.create_conversation(%{title: "Conv 1"}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conv1, actor: owner)

      {:ok, conv2} = Chat.create_conversation(%{title: "Conv 2"}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conv2, actor: owner)

      member = generate(user())

      # add_member policy uses relationship filters that can't evaluate on create
      {:ok, m1} =
        Chat.add_conversation_member(conv1.id, member.id, %{}, authorize?: false)

      {:ok, _m2} =
        Chat.add_conversation_member(conv2.id, member.id, %{}, authorize?: false)

      # Accept only one
      {:ok, _} = Chat.accept_conversation_invitation(m1, actor: member)

      {:ok, memberships} = Chat.my_conversation_memberships(actor: member)

      assert length(memberships) == 1
      assert hd(memberships).conversation_id == conv1.id
    end
  end

  describe "pending_invitations/0" do
    test "returns user's pending invitations" do
      owner = generate(user())
      {:ok, conv1} = Chat.create_conversation(%{title: "Conv 1"}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conv1, actor: owner)

      {:ok, conv2} = Chat.create_conversation(%{title: "Conv 2"}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conv2, actor: owner)

      member = generate(user())

      # add_member policy uses relationship filters that can't evaluate on create
      {:ok, m1} =
        Chat.add_conversation_member(conv1.id, member.id, %{}, authorize?: false)

      {:ok, _m2} =
        Chat.add_conversation_member(conv2.id, member.id, %{}, authorize?: false)

      # Accept only one
      {:ok, _} = Chat.accept_conversation_invitation(m1, actor: member)

      {:ok, pending} = Chat.my_pending_invitations(actor: member)

      assert length(pending) == 1
      assert hd(pending).conversation_id == conv2.id
    end
  end

  describe "remove_member/1" do
    test "member can be removed by owner" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      member_user = generate(user())

      # add_member policy uses relationship filters that can't evaluate on create
      {:ok, member} =
        Chat.add_conversation_member(conversation.id, member_user.id, %{}, authorize?: false)

      assert :ok = Chat.remove_conversation_member(member, actor: owner)
    end

    test "member can leave (remove themselves)" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      member_user = generate(user())

      # add_member policy uses relationship filters that can't evaluate on create
      {:ok, member} =
        Chat.add_conversation_member(conversation.id, member_user.id, %{}, authorize?: false)

      {:ok, _} = Chat.accept_conversation_invitation(member, actor: member_user)

      # Reload to get fresh record
      {:ok, members} = Chat.get_conversation_members(conversation.id, actor: owner)
      member = Enum.find(members, &(&1.user_id == member_user.id))

      assert :ok = Chat.remove_conversation_member(member, actor: member_user)
    end
  end
end
