defmodule Magus.Workspaces.IntegrationTest do
  @moduledoc """
  End-to-end workspace lifecycle tests covering the full flow
  from workspace creation through member management and resource sharing.
  """
  use Magus.ResourceCase, async: true

  alias Magus.Workspaces
  alias Magus.Chat
  alias Magus.Workspaces.ResourceAccess

  require Ash.Query

  defp has_workspace_grant?(conversation, workspace_id) do
    ResourceAccess
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      resource_type == :conversation and
        resource_id == ^conversation.id and
        grantee_type == :workspace and
        grantee_id == ^workspace_id
    )
    |> Ash.read!(authorize?: false)
    |> Enum.any?()
  end

  setup do
    owner = generate(user())
    member_user = generate(user())
    outsider = generate(user())
    ensure_workspace_plan(owner)
    %{owner: owner, member_user: member_user, outsider: outsider}
  end

  describe "full workspace lifecycle" do
    test "create → invite → join → share conversation → remove member",
         %{owner: owner, member_user: member_user, outsider: outsider} do
      # 1. Owner creates workspace
      {:ok, workspace} =
        Workspaces.create_workspace(%{name: "Test Team", slug: "test-team"}, actor: owner)

      assert workspace.name == "Test Team"
      assert workspace.is_active == true

      # 2. Owner invites member by email
      {:ok, invite} =
        Workspaces.invite_member(workspace.id, member_user.email, actor: owner)

      assert invite.status == :invited
      assert invite.invite_token != nil
      assert to_string(invite.invite_email) == to_string(member_user.email)

      # 3. Member accepts invite
      {:ok, accepted_member} =
        Workspaces.accept_invite(invite.invite_token, actor: member_user)

      assert accepted_member.status == :active
      assert accepted_member.is_active == true
      assert accepted_member.user_id == member_user.id

      # 4. Owner creates a conversation in workspace context
      {:ok, conversation} =
        Chat.create_conversation(
          %{workspace_id: workspace.id},
          actor: owner
        )

      assert conversation.workspace_id == workspace.id

      # 5. Owner shares conversation to team
      {:ok, shared_conversation} =
        Chat.share_conversation_to_team(conversation, actor: owner)

      assert has_workspace_grant?(shared_conversation, workspace.id)

      # 6. Member can see shared workspace conversation
      {:ok, _} = Chat.get_conversation(shared_conversation.id, actor: member_user)

      # 7. Outsider cannot see workspace conversation
      assert {:error, _} = Chat.get_conversation(shared_conversation.id, actor: outsider)

      # 8. Member creates their own private workspace conversation
      {:ok, member_conv} =
        Chat.create_conversation(
          %{workspace_id: workspace.id},
          actor: member_user
        )

      # Owner cannot see member's private conversation
      assert {:error, _} = Chat.get_conversation(member_conv.id, actor: owner)

      # 9. Member shares their conversation to team
      {:ok, _} = Chat.share_conversation_to_team(member_conv, actor: member_user)

      # Now owner can see it
      {:ok, _} = Chat.get_conversation(member_conv.id, actor: owner)

      # 10. Owner deactivates member
      {:ok, deactivated} = Workspaces.deactivate_member(accepted_member, actor: owner)
      assert deactivated.status == :deactivated
      assert deactivated.is_active == false
    end

    test "workspace member cannot invite others (only owners can)",
         %{owner: owner, member_user: member_user} do
      {:ok, workspace} =
        Workspaces.create_workspace(%{name: "Owner Only", slug: "owner-only"}, actor: owner)

      # Add member directly
      {:ok, invite} =
        Workspaces.invite_member(workspace.id, member_user.email, actor: owner)

      {:ok, _} = Workspaces.accept_invite(invite.invite_token, actor: member_user)

      # Member tries to invite someone else — should fail
      assert {:error, _} =
               Workspaces.invite_member(workspace.id, "someone@example.com", actor: member_user)
    end

    test "workspace conversations appear when listing with correct visibility",
         %{owner: owner, member_user: member_user} do
      {:ok, workspace} =
        Workspaces.create_workspace(%{name: "Visibility Test", slug: "vis-test"}, actor: owner)

      {:ok, invite} =
        Workspaces.invite_member(workspace.id, member_user.email, actor: owner)

      {:ok, _} = Workspaces.accept_invite(invite.invite_token, actor: member_user)

      # Owner creates a conversation and then shares it (which also creates
      # the workspace-level resource_access grant that backs the read policy).
      {:ok, shared} =
        Chat.create_conversation(
          %{workspace_id: workspace.id},
          actor: owner
        )

      {:ok, shared} = Chat.share_conversation_to_team(shared, actor: owner)

      # Owner creates private conversation
      {:ok, _private} =
        Chat.create_conversation(
          %{workspace_id: workspace.id},
          actor: owner
        )

      # Member can read the shared one
      {:ok, _} = Chat.get_conversation(shared.id, actor: member_user)
    end

    test "unsharing conversation removes team access",
         %{owner: owner, member_user: member_user} do
      {:ok, workspace} =
        Workspaces.create_workspace(%{name: "Unshare Test", slug: "unshare-test"}, actor: owner)

      {:ok, invite} =
        Workspaces.invite_member(workspace.id, member_user.email, actor: owner)

      {:ok, _} = Workspaces.accept_invite(invite.invite_token, actor: member_user)

      # Create and share conversation (sharing creates the workspace-level
      # resource_access grant that backs the read policy).
      {:ok, conversation} =
        Chat.create_conversation(
          %{workspace_id: workspace.id},
          actor: owner
        )

      {:ok, conversation} = Chat.share_conversation_to_team(conversation, actor: owner)

      # Member can access
      {:ok, _} = Chat.get_conversation(conversation.id, actor: member_user)

      # Owner unshares
      {:ok, _} = Chat.unshare_conversation_from_team(conversation, actor: owner)

      # Member can no longer access
      assert {:error, _} = Chat.get_conversation(conversation.id, actor: member_user)
    end
  end
end
