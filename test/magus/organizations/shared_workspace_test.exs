defmodule Magus.Organizations.SharedWorkspaceTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  require Ash.Query

  alias Magus.Organizations

  test "creating an org creates a shared workspace tagged to the org" do
    user = generate(user())
    ensure_workspace_plan(user)

    {:ok, org} =
      Organizations.create_organization(%{name: "Acme", slug: "acme-shared"}, actor: user)

    workspaces =
      Magus.Workspaces.Workspace
      |> Ash.Query.filter(organization_id == ^org.id)
      |> Ash.read!(authorize?: false)

    assert length(workspaces) == 1
    [ws] = workspaces
    assert ws.organization_id == org.id
    assert ws.name =~ "Acme"

    # creator is an active member of the shared workspace
    {:ok, members} = Magus.Workspaces.list_workspace_members(ws.id, actor: user)
    assert Enum.any?(members, &(&1.user_id == user.id and &1.is_active))
  end

  test "creating an org with a max-length (64-char) slug still creates a valid shared workspace" do
    user = generate(user())
    ensure_workspace_plan(user)

    # A valid org slug at the maximum allowed length (64 chars). The naive
    # "<org-slug>-team" scheme would overflow the 64-char workspace slug cap.
    org_slug = String.duplicate("a", 64)
    assert String.length(org_slug) == 64

    {:ok, org} =
      Organizations.create_organization(%{name: "Big Co", slug: org_slug}, actor: user)

    workspaces =
      Magus.Workspaces.Workspace
      |> Ash.Query.filter(organization_id == ^org.id)
      |> Ash.read!(authorize?: false)

    assert length(workspaces) == 1
    [ws] = workspaces
    assert ws.organization_id == org.id
    assert ws.name =~ "Big Co"

    # The derived workspace slug must satisfy the workspace slug constraints.
    assert String.length(ws.slug) <= 64
    assert ws.slug =~ ~r/\A[a-z0-9][a-z0-9-]*[a-z0-9]\z/
  end
end
