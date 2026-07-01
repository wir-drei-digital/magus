defmodule Magus.Organizations.SetMemberSpendCapTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  setup do
    owner = generate(user())
    ensure_workspace_plan(owner)
    member_user = generate(user())
    ensure_workspace_plan(member_user)

    {:ok, org} =
      Magus.Organizations.create_organization(
        %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
        actor: owner
      )

    {:ok, member} =
      Magus.Organizations.OrganizationMember
      |> Ash.Changeset.for_create(
        :create_member,
        %{
          organization_id: org.id,
          user_id: member_user.id,
          invite_email: to_string(member_user.email)
        },
        authorize?: false
      )
      |> Ash.create(authorize?: false)

    %{owner: owner, member: member, member_user: member_user, org: org}
  end

  test "owner sets a member's spend cap", %{owner: owner, member: member} do
    {:ok, updated} =
      Magus.Organizations.set_member_spend_cap(member, %{spend_cap_cents: 5000}, actor: owner)

    assert updated.spend_cap_cents == 5000
  end

  test "a non-owner cannot set a spend cap", %{member: member, member_user: member_user} do
    assert {:error, %Ash.Error.Forbidden{}} =
             Magus.Organizations.set_member_spend_cap(member, %{spend_cap_cents: 5000},
               actor: member_user
             )
  end
end
