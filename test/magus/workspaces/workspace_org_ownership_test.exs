defmodule Magus.Workspaces.WorkspaceOrgOwnershipTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Workspaces

  test "a workspace can carry an organization_id" do
    user = generate(user())
    ensure_workspace_plan(user)

    {:ok, org} =
      Magus.Organizations.create_organization(%{name: "WsOrg", slug: "ws-org"}, actor: user)

    {:ok, workspace} =
      Workspaces.create_workspace(%{name: "Tagged", slug: "tagged-ws"}, actor: user)

    {:ok, updated} =
      workspace
      |> Ash.Changeset.for_update(:set_organization, %{organization_id: org.id},
        authorize?: false
      )
      |> Ash.update()

    assert updated.organization_id == org.id
  end
end
