defmodule Magus.Skills.SkillWorkspaceTest do
  use Magus.ResourceCase, async: true

  alias Magus.Skills
  alias Magus.Workspaces

  defp add_active_member(workspace, admin_user, invitee) do
    {:ok, invite} = Workspaces.invite_member(workspace.id, invitee.email, actor: admin_user)
    {:ok, membership} = Workspaces.accept_invite(invite.invite_token, actor: invitee)
    membership
  end

  setup do
    creator = generate(user())
    member_user = generate(user())
    ensure_workspace_plan(creator)

    {:ok, workspace} =
      Workspaces.create_workspace(
        %{name: "T", slug: "skill-ws-#{System.unique_integer([:positive])}"},
        actor: creator
      )

    %{creator: creator, member_user: member_user, workspace: workspace}
  end

  test "my_skills returns only the actor's personal skills", %{
    creator: creator,
    workspace: workspace
  } do
    {:ok, _} = Skills.create_skill(%{name: "mine-a", description: "x"}, actor: creator)

    {:ok, _} =
      Skills.create_skill(
        %{name: "mine-ws", description: "x", workspace_id: workspace.id},
        actor: creator
      )

    other = generate(user())
    {:ok, _} = Skills.create_skill(%{name: "theirs", description: "x"}, actor: other)

    names = Skills.my_skills!(actor: creator) |> Enum.map(& &1.name)
    assert "mine-a" in names
    refute "mine-ws" in names
    refute "theirs" in names
  end

  test "private workspace skill is hidden from a member without a grant", %{
    creator: creator,
    member_user: member_user,
    workspace: workspace
  } do
    {:ok, skill} =
      Skills.create_skill(
        %{name: "ws-private", description: "x", workspace_id: workspace.id},
        actor: creator
      )

    _ = add_active_member(workspace, creator, member_user)
    assert {:error, _} = Skills.get_skill(skill.id, actor: member_user)
  end

  test "share_to_team creates a workspace grant and the member can read", %{
    creator: creator,
    member_user: member_user,
    workspace: workspace
  } do
    {:ok, skill} =
      Skills.create_skill(
        %{name: "ws-shared", description: "x", workspace_id: workspace.id},
        actor: creator
      )

    _ = add_active_member(workspace, creator, member_user)
    assert {:error, _} = Skills.get_skill(skill.id, actor: member_user)

    {:ok, _} = Skills.share_skill_to_team(skill, actor: creator)
    assert {:ok, _} = Skills.get_skill(skill.id, actor: member_user)
  end
end
