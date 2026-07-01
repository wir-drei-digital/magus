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
end
