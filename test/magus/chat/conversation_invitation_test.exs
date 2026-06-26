defmodule Magus.Chat.ConversationInvitationTest do
  @moduledoc """
  Tests for ConversationInvitation resource.

  Tests email-based invitations for multiplayer conversations including:
  - Creating invitations with token generation
  - Looking up invitations by token
  - Accepting invitations
  """
  use Magus.ResourceCase, async: true

  alias Magus.Chat

  describe "create/1" do
    test "creates invitation with generated token" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      {:ok, invitation} =
        Chat.create_invitation(
          conversation.id,
          %{email: "invited@example.com"},
          actor: owner
        )

      assert invitation.email != nil
      assert to_string(invitation.email) == "invited@example.com"
      assert invitation.token != nil
      assert String.length(invitation.token) > 0
      assert invitation.role == :member
      assert invitation.accepted_at == nil
      assert invitation.invited_by_id == owner.id
    end

    test "creates invitation with specific role" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      {:ok, invitation} =
        Chat.create_invitation(
          conversation.id,
          %{email: "observer@example.com", role: :observer},
          actor: owner
        )

      assert invitation.role == :observer
    end

    test "prevents duplicate invitation to same email" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      {:ok, _} =
        Chat.create_invitation(
          conversation.id,
          %{email: "duplicate@example.com"},
          actor: owner
        )

      # Duplicate invitation returns an error (constraint violation)
      assert {:error, _} =
               Chat.create_invitation(
                 conversation.id,
                 %{email: "duplicate@example.com"},
                 actor: owner
               )
    end

    test "non-owner cannot create invitation" do
      owner = generate(user())
      non_owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      assert {:error, %Ash.Error.Forbidden{}} =
               Chat.create_invitation(
                 conversation.id,
                 %{email: "invited@example.com"},
                 actor: non_owner
               )
    end
  end

  describe "by_token/1" do
    test "finds invitation by token" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      {:ok, invitation} =
        Chat.create_invitation(
          conversation.id,
          %{email: "find@example.com"},
          actor: owner
        )

      {:ok, found} = Chat.get_invitation_by_token(invitation.token, authorize?: false)

      assert found.id == invitation.id
    end

    test "returns error for invalid token" do
      assert {:error, _} = Chat.get_invitation_by_token("invalid-token", authorize?: false)
    end

    test "does not find accepted invitation" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      {:ok, invitation} =
        Chat.create_invitation(
          conversation.id,
          %{email: "accepted@example.com"},
          actor: owner
        )

      {:ok, _} = Chat.accept_invitation(invitation, authorize?: false)

      assert {:error, _} = Chat.get_invitation_by_token(invitation.token, authorize?: false)
    end
  end

  describe "by_email/2" do
    test "finds invitation by email and conversation" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      {:ok, invitation} =
        Chat.create_invitation(
          conversation.id,
          %{email: "lookup@example.com"},
          actor: owner
        )

      {:ok, found} =
        Chat.get_invitation_by_email("lookup@example.com", conversation.id, authorize?: false)

      assert found.id == invitation.id
    end

    test "returns error when not found" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      assert {:error, _} =
               Chat.get_invitation_by_email("notfound@example.com", conversation.id,
                 authorize?: false
               )
    end
  end

  describe "pending_for_conversation/1" do
    test "returns pending invitations for conversation" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      {:ok, inv1} =
        Chat.create_invitation(
          conversation.id,
          %{email: "pending1@example.com"},
          actor: owner
        )

      {:ok, inv2} =
        Chat.create_invitation(
          conversation.id,
          %{email: "pending2@example.com"},
          actor: owner
        )

      # Accept one
      {:ok, _} = Chat.accept_invitation(inv1, authorize?: false)

      {:ok, pending} = Chat.get_pending_invitations(conversation.id, actor: owner)

      assert length(pending) == 1
      assert hd(pending).id == inv2.id
    end
  end

  describe "accept/1" do
    test "sets accepted_at timestamp" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      {:ok, invitation} =
        Chat.create_invitation(
          conversation.id,
          %{email: "toaccept@example.com"},
          actor: owner
        )

      assert invitation.accepted_at == nil

      {:ok, accepted} = Chat.accept_invitation(invitation, authorize?: false)

      assert accepted.accepted_at != nil
    end
  end

  describe "destroy/1" do
    test "deletes invitation" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      {:ok, invitation} =
        Chat.create_invitation(
          conversation.id,
          %{email: "todelete@example.com"},
          actor: owner
        )

      assert :ok = Chat.delete_invitation(invitation, authorize?: false)

      assert {:error, _} = Chat.get_invitation_by_token(invitation.token, authorize?: false)
    end
  end
end
