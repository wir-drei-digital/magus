defmodule Magus.Workspaces.WorkspaceAutotagTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Workspaces

  test "org member's new workspace is tagged to their org" do
    owner = generate(user())
    ensure_workspace_plan(owner)

    {:ok, org} =
      Magus.Organizations.create_organization(%{name: "Tag", slug: "tag-org"}, actor: owner)

    {:ok, ws} = Workspaces.create_workspace(%{name: "Owned", slug: "owned-ws"}, actor: owner)
    assert ws.organization_id == org.id
  end

  test "non-member's new workspace is not tagged" do
    solo = generate(user())
    ensure_workspace_plan(solo)

    {:ok, ws} = Workspaces.create_workspace(%{name: "Solo", slug: "solo-ws"}, actor: solo)
    assert ws.organization_id == nil
  end
end
