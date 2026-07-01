defmodule Magus.Organizations.MyOrganizationTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  test "my_organization returns the actor's active membership + org" do
    owner = generate(user())
    ensure_workspace_plan(owner)

    {:ok, org} =
      Magus.Organizations.create_organization(
        %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
        actor: owner
      )

    {:ok, [membership]} = Magus.Organizations.my_organization(actor: owner)
    assert membership.organization_id == org.id
    assert membership.role == :owner
    assert membership.organization.id == org.id

    other = generate(user())
    ensure_workspace_plan(other)
    assert {:ok, []} = Magus.Organizations.my_organization(actor: other)
  end
end
