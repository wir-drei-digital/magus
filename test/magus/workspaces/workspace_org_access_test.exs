defmodule Magus.Workspaces.WorkspaceOrgAccessTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Workspaces

  test "org owner can read a member's org workspace they are not a WorkspaceMember of" do
    owner = generate(user())
    ensure_workspace_plan(owner)

    {:ok, org} =
      Magus.Organizations.create_organization(%{name: "Acc", slug: "acc-org"}, actor: owner)

    member_user = generate(user())
    {:ok, invite} = Magus.Organizations.invite_org_member(org.id, member_user.email, actor: owner)
    {:ok, _} = Magus.Organizations.accept_invite(invite.invite_token, actor: member_user)

    # member creates a workspace (auto-tagged to org). Owner is NOT a WorkspaceMember of it.
    {:ok, member_ws} =
      Workspaces.create_workspace(%{name: "Member WS", slug: "member-ws"}, actor: member_user)

    assert member_ws.organization_id == org.id

    # owner can read it despite not being a WorkspaceMember
    assert {:ok, _} = Workspaces.get_workspace(member_ws.id, actor: owner)
  end
end
