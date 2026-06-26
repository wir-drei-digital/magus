defmodule Magus.Workspaces.WorkspaceMemberTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Workspaces

  describe "role attribute constraint" do
    setup do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, workspace} =
        Workspaces.create_workspace(%{name: "Role WS", slug: "role-ws"}, actor: user)

      %{user: user, workspace: workspace}
    end

    test "accepts :admin as a valid role", %{user: user, workspace: workspace} do
      other = generate(user())

      member =
        Magus.Workspaces.WorkspaceMember
        |> Ash.Changeset.for_create(:create_member, %{
          workspace_id: workspace.id,
          user_id: other.id,
          invite_email: other.email
        })
        |> Ash.create!(authorize?: false)

      {:ok, promoted} =
        member
        |> Ash.Changeset.for_update(:change_role, %{role: :admin}, actor: user)
        |> Ash.update()

      assert promoted.role == :admin
    end

    test "rejects :owner as a role value", %{user: user, workspace: workspace} do
      other = generate(user())

      member =
        Magus.Workspaces.WorkspaceMember
        |> Ash.Changeset.for_create(:create_member, %{
          workspace_id: workspace.id,
          user_id: other.id,
          invite_email: other.email
        })
        |> Ash.create!(authorize?: false)

      assert {:error, %Ash.Error.Invalid{} = err} =
               member
               |> Ash.Changeset.for_update(:change_role, %{role: :owner}, actor: user)
               |> Ash.update()

      assert Exception.message(err) =~ ~s|atom must be one of "admin, member"|
    end
  end

  describe "auto-create owner on workspace creation" do
    test "creating a workspace auto-creates owner member" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, workspace} =
        Workspaces.create_workspace(%{name: "Test WS", slug: "test-ws"}, actor: user)

      {:ok, members} = Workspaces.list_workspace_members(workspace.id, actor: user)

      assert length(members) == 1
      [owner] = members
      assert owner.workspace_id == workspace.id
      assert owner.user_id == user.id
      assert owner.role == :admin
      assert owner.status == :active
      assert owner.is_active == true
      assert owner.joined_at != nil
      assert owner.invited_at != nil
      assert owner.invite_token != nil
      assert owner.invite_email == to_string(user.email)
    end
  end

  describe "invite" do
    setup do
      owner = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Workspaces.create_workspace(%{name: "Invite WS", slug: "invite-ws"}, actor: owner)

      %{owner: owner, workspace: workspace}
    end

    test "owner can invite a member by email", %{owner: owner, workspace: workspace} do
      {:ok, invite} =
        Workspaces.invite_member(workspace.id, "newmember@test.com", actor: owner)

      assert invite.workspace_id == workspace.id
      assert invite.invite_email == "newmember@test.com"
      assert invite.role == :member
      assert invite.status == :invited
      assert invite.is_active == false
      assert invite.invited_at != nil
      assert invite.invite_token != nil
      assert invite.user_id == nil
      assert invite.joined_at == nil
    end

    test "non-owner cannot invite", %{workspace: workspace} do
      non_owner = generate(user())

      # Add non_owner as a member directly so they have read access
      Magus.Workspaces.WorkspaceMember
      |> Ash.Changeset.for_create(:create_member, %{
        workspace_id: workspace.id,
        user_id: non_owner.id,
        invite_email: non_owner.email
      })
      |> Ash.create!(authorize?: false)

      assert {:error, %Ash.Error.Forbidden{}} =
               Workspaces.invite_member(workspace.id, "someone@test.com", actor: non_owner)
    end

    test "free-plan owner can invite arbitrarily many members", %{
      owner: owner,
      workspace: workspace
    } do
      for i <- 1..3 do
        assert {:ok, _} =
                 Workspaces.invite_member(workspace.id, "invitee-#{i}@test.com", actor: owner)
      end
    end
  end

  describe "accept invite" do
    setup do
      owner = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Workspaces.create_workspace(%{name: "Accept WS", slug: "accept-ws"}, actor: owner)

      {:ok, invite} = Workspaces.invite_member(workspace.id, "invitee@test.com", actor: owner)

      %{owner: owner, workspace: workspace, invite: invite}
    end

    test "accepting invite activates membership", %{invite: invite} do
      accepting_user = generate(user())

      {:ok, member} = Workspaces.accept_invite(invite.invite_token, actor: accepting_user)

      assert member.status == :active
      assert member.is_active == true
      assert member.user_id == accepting_user.id
      assert member.joined_at != nil
    end

    test "invalid token returns error" do
      accepting_user = generate(user())

      assert {:error, _} = Workspaces.accept_invite("bogus-token", actor: accepting_user)
    end
  end

  describe "deactivate" do
    setup do
      owner = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Workspaces.create_workspace(%{name: "Deactivate WS", slug: "deactivate-ws"}, actor: owner)

      member_user = generate(user())

      member =
        Magus.Workspaces.WorkspaceMember
        |> Ash.Changeset.for_create(:create_member, %{
          workspace_id: workspace.id,
          user_id: member_user.id,
          invite_email: member_user.email
        })
        |> Ash.create!(authorize?: false)

      %{owner: owner, workspace: workspace, member: member, member_user: member_user}
    end

    test "owner can deactivate a member", %{owner: owner, member: member} do
      {:ok, deactivated} = Workspaces.deactivate_member(member, actor: owner)

      assert deactivated.status == :deactivated
      assert deactivated.is_active == false
      assert deactivated.deactivated_at != nil
    end

    test "deactivated member has is_active=false", %{owner: owner, member: member} do
      {:ok, deactivated} = Workspaces.deactivate_member(member, actor: owner)

      assert deactivated.is_active == false
    end

    test "cannot deactivate last admin", %{owner: owner, workspace: workspace} do
      # Find the admin member record
      {:ok, members} = Workspaces.list_workspace_members(workspace.id, actor: owner)
      admin_member = Enum.find(members, &(&1.role == :admin))

      assert {:error, error} = Workspaces.deactivate_member(admin_member, actor: owner)
      assert Exception.message(error) =~ "last admin"
    end
  end

  describe "my_workspaces" do
    test "returns workspaces for active members only" do
      owner = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Workspaces.create_workspace(%{name: "Active WS", slug: "active-ws"}, actor: owner)

      member_user = generate(user())

      member =
        Magus.Workspaces.WorkspaceMember
        |> Ash.Changeset.for_create(:create_member, %{
          workspace_id: workspace.id,
          user_id: member_user.id,
          invite_email: member_user.email
        })
        |> Ash.create!(authorize?: false)

      # Member can see the workspace
      {:ok, workspaces} = Workspaces.my_workspaces(actor: member_user)
      assert length(workspaces) == 1
      assert hd(workspaces).id == workspace.id

      # Deactivate the member
      {:ok, _} = Workspaces.deactivate_member(member, actor: owner)

      # Deactivated member can no longer see the workspace
      {:ok, workspaces} = Workspaces.my_workspaces(actor: member_user)
      assert workspaces == []
    end
  end
end
