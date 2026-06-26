defmodule Magus.Chat.ConversationWorkspaceTest do
  @moduledoc """
  Tests for the generic workspace-scoped policy on `Magus.Chat.Conversation`
  backed by `Magus.Workspaces.ResourceAccess` grants. Also covers the
  multiplayer `ConversationMember` extra_read/extra_update rules and the
  `share_to_team` / `unshare_from_team` grant sync.
  """
  use Magus.ResourceCase, async: true

  alias Magus.Chat
  alias Magus.Workspaces
  alias Magus.Workspaces.ResourceAccess

  require Ash.Query

  defp add_active_member(workspace, admin_user, invitee) do
    {:ok, invite} =
      Workspaces.invite_member(workspace.id, invitee.email, actor: admin_user)

    {:ok, membership} = Workspaces.accept_invite(invite.invite_token, actor: invitee)
    membership
  end

  defp grant!(attrs) do
    {:ok, grant} =
      ResourceAccess
      |> Ash.Changeset.for_create(:grant, attrs)
      |> Ash.create(authorize?: false)

    grant
  end

  defp grants_for(conv) do
    ResourceAccess
    |> Ash.Query.for_read(:for_resource, %{resource_type: :conversation, resource_id: conv.id})
    |> Ash.read!(authorize?: false)
  end

  describe "workspace scoping" do
    setup do
      creator = generate(user())
      stranger = generate(user())
      ensure_workspace_plan(creator)

      {:ok, workspace} =
        Workspaces.create_workspace(
          %{name: "T", slug: "t-conv-#{System.unique_integer([:positive])}"},
          actor: creator
        )

      %{creator: creator, stranger: stranger, workspace: workspace}
    end

    test "creator can read their own workspace conversation", %{
      creator: creator,
      workspace: workspace
    } do
      {:ok, conv} =
        Chat.create_conversation(
          %{workspace_id: workspace.id},
          actor: creator
        )

      assert {:ok, _} = Chat.get_conversation(conv.id, actor: creator)
    end

    test "private workspace conversation (no grant) is hidden from active members", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, conv} =
        Chat.create_conversation(
          %{workspace_id: workspace.id},
          actor: creator
        )

      _ = add_active_member(workspace, creator, stranger)

      assert {:error, _} = Chat.get_conversation(conv.id, actor: stranger)
    end

    test "workspace :viewer grant lets an active member read the conversation", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, conv} =
        Chat.create_conversation(
          %{workspace_id: workspace.id},
          actor: creator
        )

      _ = add_active_member(workspace, creator, stranger)

      _grant =
        grant!(%{
          resource_type: :conversation,
          resource_id: conv.id,
          grantee_type: :workspace,
          grantee_id: workspace.id,
          role: :viewer
        })

      assert {:ok, _} = Chat.get_conversation(conv.id, actor: stranger)
    end

    test "stranger (non-member) cannot see conversation even with workspace grant", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, conv} =
        Chat.create_conversation(
          %{workspace_id: workspace.id},
          actor: creator
        )

      _grant =
        grant!(%{
          resource_type: :conversation,
          resource_id: conv.id,
          grantee_type: :workspace,
          grantee_id: workspace.id,
          role: :viewer
        })

      assert {:error, _} = Chat.get_conversation(conv.id, actor: stranger)
    end
  end

  describe "multiplayer ConversationMember extra_read" do
    test "accepted multiplayer member can read a conversation without a workspace grant" do
      owner = generate(user())
      member_user = generate(user())

      {:ok, conv} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conv, actor: owner)

      {:ok, membership} =
        Chat.add_conversation_member(
          conv.id,
          member_user.id,
          %{invited_by_id: owner.id},
          authorize?: false
        )

      # Before accepting, member cannot read.
      assert {:error, _} = Chat.get_conversation(conv.id, actor: member_user)

      {:ok, _} =
        membership
        |> Ash.Changeset.for_update(:accept_invitation, %{}, authorize?: false)
        |> Ash.update()

      # After accepting, member can read via the :extra_read rule.
      assert {:ok, _} = Chat.get_conversation(conv.id, actor: member_user)
    end
  end

  describe "share_to_team / unshare_from_team grant sync" do
    setup do
      creator = generate(user())
      member_user = generate(user())
      ensure_workspace_plan(creator)

      {:ok, workspace} =
        Workspaces.create_workspace(
          %{name: "T", slug: "t-share-#{System.unique_integer([:positive])}"},
          actor: creator
        )

      _ = add_active_member(workspace, creator, member_user)

      {:ok, conv} =
        Chat.create_conversation(
          %{workspace_id: workspace.id},
          actor: creator
        )

      %{
        creator: creator,
        member_user: member_user,
        workspace: workspace,
        conv: conv
      }
    end

    test "share_to_team creates a workspace grant", %{
      creator: creator,
      workspace: workspace,
      conv: conv
    } do
      assert grants_for(conv) == []

      {:ok, _shared} = Chat.share_conversation_to_team(conv, actor: creator)

      grants = grants_for(conv)
      assert length(grants) == 1

      [g] = grants
      assert g.resource_type == :conversation
      assert g.resource_id == conv.id
      assert g.grantee_type == :workspace
      assert g.grantee_id == workspace.id
      assert g.role == :viewer
    end

    test "share_to_team is idempotent when run twice", %{
      creator: creator,
      conv: conv
    } do
      {:ok, _} = Chat.share_conversation_to_team(conv, actor: creator)
      {:ok, _} = Chat.share_conversation_to_team(conv, actor: creator)

      assert length(grants_for(conv)) == 1
    end

    test "shared conversation is readable by active workspace member via grant", %{
      creator: creator,
      member_user: member_user,
      conv: conv
    } do
      # Not readable before sharing.
      assert {:error, _} = Chat.get_conversation(conv.id, actor: member_user)

      {:ok, _} = Chat.share_conversation_to_team(conv, actor: creator)

      assert {:ok, _} = Chat.get_conversation(conv.id, actor: member_user)
    end

    test "unshare_from_team removes the workspace grant", %{
      creator: creator,
      member_user: member_user,
      conv: conv
    } do
      {:ok, _} = Chat.share_conversation_to_team(conv, actor: creator)
      assert length(grants_for(conv)) == 1
      assert {:ok, _} = Chat.get_conversation(conv.id, actor: member_user)

      {:ok, _unshared} = Chat.unshare_conversation_from_team(conv, actor: creator)

      assert grants_for(conv) == []
      assert {:error, _} = Chat.get_conversation(conv.id, actor: member_user)
    end

    test "unshare_from_team broadcasts access_revoked on chat:access topic", %{
      creator: creator,
      conv: conv
    } do
      {:ok, _} = Chat.share_conversation_to_team(conv, actor: creator)

      MagusWeb.Endpoint.subscribe("chat:access:#{conv.id}")

      {:ok, _unshared} = Chat.unshare_conversation_from_team(conv, actor: creator)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: topic,
        event: "access_revoked",
        payload: %{conversation_id: id}
      }

      assert topic == "chat:access:#{conv.id}"
      assert id == conv.id
    end
  end

  describe "is_collaborative calculation" do
    test "is false for a private personal conversation" do
      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{}, actor: user)

      {:ok, loaded} = Chat.get_conversation(conv.id, actor: user, load: [:is_collaborative])
      assert loaded.is_collaborative == false
    end

    test "is true when the conversation is in multiplayer mode" do
      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{}, actor: user)
      {:ok, conv} = Chat.enable_multiplayer(conv, actor: user)

      {:ok, loaded} = Chat.get_conversation(conv.id, actor: user, load: [:is_collaborative])
      assert loaded.is_collaborative == true
    end

    test "is true when a workspace grant exists for the conversation" do
      creator = generate(user())
      ensure_workspace_plan(creator)

      {:ok, workspace} =
        Workspaces.create_workspace(
          %{name: "T", slug: "t-collab-#{System.unique_integer([:positive])}"},
          actor: creator
        )

      {:ok, conv} =
        Chat.create_conversation(%{workspace_id: workspace.id}, actor: creator)

      {:ok, _} = Chat.share_conversation_to_team(conv, actor: creator)

      {:ok, loaded} = Chat.get_conversation(conv.id, actor: creator, load: [:is_collaborative])
      assert loaded.is_collaborative == true
    end

    test "is false for a workspace conversation without a grant" do
      creator = generate(user())
      ensure_workspace_plan(creator)

      {:ok, workspace} =
        Workspaces.create_workspace(
          %{name: "T", slug: "t-collab-no-#{System.unique_integer([:positive])}"},
          actor: creator
        )

      {:ok, conv} =
        Chat.create_conversation(%{workspace_id: workspace.id}, actor: creator)

      {:ok, loaded} = Chat.get_conversation(conv.id, actor: creator, load: [:is_collaborative])
      assert loaded.is_collaborative == false
    end
  end

  describe "destroy grant cleanup" do
    test "delete_full_conversation cleans up ResourceAccess grants" do
      creator = generate(user())
      ensure_workspace_plan(creator)

      {:ok, workspace} =
        Workspaces.create_workspace(
          %{name: "T", slug: "t-destroy-#{System.unique_integer([:positive])}"},
          actor: creator
        )

      {:ok, conv} =
        Chat.create_conversation(
          %{workspace_id: workspace.id},
          actor: creator
        )

      {:ok, _} = Chat.share_conversation_to_team(conv, actor: creator)
      assert length(grants_for(conv)) == 1

      :ok = Chat.delete_full_conversation(conv, actor: creator)

      assert grants_for(conv) == []
    end
  end
end
