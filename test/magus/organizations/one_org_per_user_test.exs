defmodule Magus.Organizations.OneOrgPerUserTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Organizations

  test "a user cannot become an active member of a second org" do
    owner_a = generate(user())
    ensure_workspace_plan(owner_a)
    {:ok, org_a} = Organizations.create_organization(%{name: "A", slug: "one-a"}, actor: owner_a)

    joiner = generate(user())

    # Active in org A
    Magus.Organizations.OrganizationMember
    |> Ash.Changeset.for_create(:create_member, %{
      organization_id: org_a.id,
      user_id: joiner.id,
      invite_email: joiner.email
    })
    |> Ash.create!(authorize?: false)

    owner_b = generate(user())
    ensure_workspace_plan(owner_b)
    {:ok, org_b} = Organizations.create_organization(%{name: "B", slug: "one-b"}, actor: owner_b)

    assert {:error, %Ash.Error.Invalid{} = err} =
             Magus.Organizations.OrganizationMember
             |> Ash.Changeset.for_create(:create_member, %{
               organization_id: org_b.id,
               user_id: joiner.id,
               invite_email: joiner.email
             })
             |> Ash.create()

    assert Exception.message(err) =~ "already belongs to an organization"
  end
end
