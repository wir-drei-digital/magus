defmodule Magus.Chat.ConversationShareLinkTest do
  @moduledoc """
  Tests for ConversationShareLink resource.

  Tests read-only share links for conversations including:
  - Creating share links with token generation
  - Looking up share links by token
  - Revoking share links
  - Policy enforcement for owners vs non-owners
  - Access type (public vs authenticated)
  """
  use Magus.ResourceCase, async: true

  alias Magus.Chat

  describe "create/1" do
    test "creates share link with generated token" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      {:ok, share_link} =
        Chat.create_share_link(
          conversation.id,
          %{},
          actor: owner
        )

      assert share_link.token != nil
      assert String.length(share_link.token) > 0
      assert share_link.access_type == :public
      assert share_link.is_active == true
      assert share_link.conversation_id == conversation.id
      assert share_link.created_by_id == owner.id
    end

    test "creates share link with public access type" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      {:ok, share_link} =
        Chat.create_share_link(
          conversation.id,
          %{access_type: :public},
          actor: owner
        )

      assert share_link.access_type == :public
    end

    test "creates share link with authenticated access type" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      {:ok, share_link} =
        Chat.create_share_link(
          conversation.id,
          %{access_type: :authenticated},
          actor: owner
        )

      assert share_link.access_type == :authenticated
    end

    test "creates share link with optional label" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      {:ok, share_link} =
        Chat.create_share_link(
          conversation.id,
          %{label: "For team review"},
          actor: owner
        )

      assert share_link.label == "For team review"
    end

    test "generates unique tokens for each share link" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      {:ok, link1} = Chat.create_share_link(conversation.id, %{}, actor: owner)
      {:ok, link2} = Chat.create_share_link(conversation.id, %{}, actor: owner)

      assert link1.token != link2.token
    end

    test "non-owner cannot create share link" do
      owner = generate(user())
      non_owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      assert {:error, %Ash.Error.Forbidden{}} =
               Chat.create_share_link(
                 conversation.id,
                 %{},
                 actor: non_owner
               )
    end

    test "can create multiple share links for same conversation" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      {:ok, link1} = Chat.create_share_link(conversation.id, %{label: "Link 1"}, actor: owner)
      {:ok, link2} = Chat.create_share_link(conversation.id, %{label: "Link 2"}, actor: owner)
      {:ok, link3} = Chat.create_share_link(conversation.id, %{label: "Link 3"}, actor: owner)

      assert link1.id != link2.id
      assert link2.id != link3.id
    end
  end

  describe "by_token/1" do
    test "finds share link by token" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      {:ok, share_link} =
        Chat.create_share_link(conversation.id, %{}, actor: owner)

      {:ok, found} = Chat.get_share_link_by_token(share_link.token, authorize?: false)

      assert found.id == share_link.id
    end

    test "returns error for invalid token" do
      assert {:error, _} =
               Chat.get_share_link_by_token("invalid-nonexistent-token", authorize?: false)
    end

    test "does not find revoked share link" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      {:ok, share_link} =
        Chat.create_share_link(conversation.id, %{}, actor: owner)

      {:ok, _} = Chat.revoke_share_link(share_link, actor: owner)

      assert {:error, _} = Chat.get_share_link_by_token(share_link.token, authorize?: false)
    end

    test "anyone can look up share link by token (public access)" do
      owner = generate(user())
      random_user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      {:ok, share_link} =
        Chat.create_share_link(conversation.id, %{}, actor: owner)

      # Token lookup should work without actor (for public viewing)
      {:ok, found} = Chat.get_share_link_by_token(share_link.token, authorize?: false)
      assert found.id == share_link.id

      # Should also work with any actor
      {:ok, found_with_actor} = Chat.get_share_link_by_token(share_link.token, actor: random_user)
      assert found_with_actor.id == share_link.id
    end
  end

  describe "active_for_conversation/1" do
    test "returns active share links for conversation" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      {:ok, link1} = Chat.create_share_link(conversation.id, %{label: "Active 1"}, actor: owner)
      {:ok, link2} = Chat.create_share_link(conversation.id, %{label: "Active 2"}, actor: owner)

      {:ok, link3} =
        Chat.create_share_link(conversation.id, %{label: "To be revoked"}, actor: owner)

      # Revoke one
      {:ok, _} = Chat.revoke_share_link(link3, actor: owner)

      {:ok, active_links} = Chat.get_active_share_links(conversation.id, actor: owner)

      assert length(active_links) == 2
      active_ids = Enum.map(active_links, & &1.id)
      assert link1.id in active_ids
      assert link2.id in active_ids
      refute link3.id in active_ids
    end

    test "returns empty list when no active share links" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      {:ok, active_links} = Chat.get_active_share_links(conversation.id, actor: owner)

      assert active_links == []
    end

    test "non-owner cannot list share links" do
      owner = generate(user())
      non_owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      {:ok, _} = Chat.create_share_link(conversation.id, %{}, actor: owner)

      {:ok, links} = Chat.get_active_share_links(conversation.id, actor: non_owner)
      # Non-owner should get empty list due to policy
      assert links == []
    end

    test "orders by inserted_at descending (newest first)" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      {:ok, link1} = Chat.create_share_link(conversation.id, %{label: "First"}, actor: owner)
      :timer.sleep(10)
      {:ok, link2} = Chat.create_share_link(conversation.id, %{label: "Second"}, actor: owner)
      :timer.sleep(10)
      {:ok, link3} = Chat.create_share_link(conversation.id, %{label: "Third"}, actor: owner)

      {:ok, active_links} = Chat.get_active_share_links(conversation.id, actor: owner)

      # Should be ordered newest first
      [first, second, third] = active_links
      assert first.id == link3.id
      assert second.id == link2.id
      assert third.id == link1.id
    end
  end

  describe "revoke/1" do
    test "sets is_active to false" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      {:ok, share_link} =
        Chat.create_share_link(conversation.id, %{}, actor: owner)

      assert share_link.is_active == true

      {:ok, revoked} = Chat.revoke_share_link(share_link, actor: owner)

      assert revoked.is_active == false
    end

    test "non-owner cannot revoke share link" do
      owner = generate(user())
      non_owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      {:ok, share_link} =
        Chat.create_share_link(conversation.id, %{}, actor: owner)

      assert {:error, %Ash.Error.Forbidden{}} =
               Chat.revoke_share_link(share_link, actor: non_owner)
    end

    test "revoked link cannot be found by token" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      {:ok, share_link} =
        Chat.create_share_link(conversation.id, %{}, actor: owner)

      {:ok, found_before} = Chat.get_share_link_by_token(share_link.token, authorize?: false)
      assert found_before.id == share_link.id

      {:ok, _} = Chat.revoke_share_link(share_link, actor: owner)

      assert {:error, _} = Chat.get_share_link_by_token(share_link.token, authorize?: false)
    end
  end

  describe "destroy/1" do
    test "deletes share link" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      {:ok, share_link} =
        Chat.create_share_link(conversation.id, %{}, actor: owner)

      assert :ok = Chat.delete_share_link(share_link, actor: owner)

      assert {:error, _} = Chat.get_share_link_by_token(share_link.token, authorize?: false)
    end

    test "non-owner cannot delete share link" do
      owner = generate(user())
      non_owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      {:ok, share_link} =
        Chat.create_share_link(conversation.id, %{}, actor: owner)

      assert {:error, %Ash.Error.Forbidden{}} =
               Chat.delete_share_link(share_link, actor: non_owner)
    end
  end

  describe "share links cascade delete with conversation" do
    test "share links are deleted when conversation is deleted" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      {:ok, share_link} =
        Chat.create_share_link(conversation.id, %{}, actor: owner)

      token = share_link.token

      # Delete conversation
      :ok = Chat.delete_full_conversation(conversation, actor: owner)

      # Share link should be gone
      assert {:error, _} = Chat.get_share_link_by_token(token, authorize?: false)
    end
  end

  describe "disable_multiplayer/1" do
    test "owner can disable multiplayer" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, conversation} = Chat.enable_multiplayer(conversation, actor: owner)

      assert conversation.is_multiplayer == true

      {:ok, updated} = Chat.disable_multiplayer(conversation, actor: owner)

      assert updated.is_multiplayer == false
    end

    test "disabling multiplayer removes non-owner members" do
      owner = generate(user())
      member1 = generate(user())
      member2 = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, conversation} = Chat.enable_multiplayer(conversation, actor: owner)

      # Add members
      {:ok, membership1} =
        Chat.add_conversation_member(conversation.id, member1.id, %{}, authorize?: false)

      {:ok, _} = Chat.accept_conversation_invitation(membership1, actor: member1)

      {:ok, membership2} =
        Chat.add_conversation_member(conversation.id, member2.id, %{}, authorize?: false)

      {:ok, _} = Chat.accept_conversation_invitation(membership2, actor: member2)

      # Verify members exist
      {:ok, members_before} = Chat.get_conversation_members(conversation.id, actor: owner)
      assert length(members_before) == 3

      # Disable multiplayer
      {:ok, _} = Chat.disable_multiplayer(conversation, actor: owner)

      # Verify non-owner members are removed
      {:ok, members_after} = Chat.get_conversation_members(conversation.id, authorize?: false)
      assert length(members_after) == 1
      assert hd(members_after).user_id == owner.id
    end

    test "non-owner cannot disable multiplayer" do
      owner = generate(user())
      member = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, conversation} = Chat.enable_multiplayer(conversation, actor: owner)

      {:ok, membership} =
        Chat.add_conversation_member(conversation.id, member.id, %{}, authorize?: false)

      {:ok, _} = Chat.accept_conversation_invitation(membership, actor: member)

      assert {:error, %Ash.Error.Forbidden{}} =
               Chat.disable_multiplayer(conversation, actor: member)
    end
  end
end
