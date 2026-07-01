defmodule Magus.Organizations.AcceptAddsWorkspaceTest do
  use Magus.DataCase, async: true
  import Magus.Generators
  require Ash.Query

  test "accepting an org invite adds the member to the org's shared workspace" do
    owner = generate(user())
    ensure_workspace_plan(owner)
    invitee = generate(user())
    ensure_workspace_plan(invitee)

    {:ok, org} =
      Magus.Organizations.create_organization(
        %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
        actor: owner
      )

    {:ok, member} =
      Magus.Organizations.invite_org_member(org.id, to_string(invitee.email), actor: owner)

    {:ok, _} = Magus.Organizations.accept_invite(member.invite_token, actor: invitee)

    shared =
      Magus.Workspaces.Workspace
      |> Ash.Query.filter(organization_id == ^org.id)
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.read!(authorize?: false)
      |> List.first()

    members =
      Magus.Workspaces.WorkspaceMember
      |> Ash.Query.filter(workspace_id == ^shared.id and user_id == ^invitee.id)
      |> Ash.read!(authorize?: false)

    assert length(members) == 1

    # Idempotent: replaying the accept action must not crash or duplicate the
    # workspace membership (the invitee is already a shared-workspace member).
    member
    |> Ash.Changeset.for_update(:accept, %{}, actor: invitee, authorize?: false)
    |> Ash.update!()

    members_after =
      Magus.Workspaces.WorkspaceMember
      |> Ash.Query.filter(workspace_id == ^shared.id and user_id == ^invitee.id)
      |> Ash.read!(authorize?: false)

    assert length(members_after) == 1
  end
end
