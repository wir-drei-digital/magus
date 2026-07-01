defmodule Magus.Organizations.OrganizationAuthzTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Organizations

  test "non-owner cannot invite" do
    owner = generate(user())
    ensure_workspace_plan(owner)
    {:ok, org} = Organizations.create_organization(%{name: "O", slug: "authz-org"}, actor: owner)

    non_owner = generate(user())

    # Add non_owner as a plain member so they have read access
    Magus.Organizations.OrganizationMember
    |> Ash.Changeset.for_create(:create_member, %{
      organization_id: org.id,
      user_id: non_owner.id,
      invite_email: non_owner.email
    })
    |> Ash.create!(authorize?: false)

    assert {:error, %Ash.Error.Forbidden{}} =
             Organizations.invite_org_member(org.id, "x@test.com", actor: non_owner)
  end

  test "owner can invite" do
    owner = generate(user())
    ensure_workspace_plan(owner)
    {:ok, org} = Organizations.create_organization(%{name: "O", slug: "authz-org2"}, actor: owner)

    assert {:ok, _} = Organizations.invite_org_member(org.id, "y@test.com", actor: owner)
  end
end
