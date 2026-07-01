defmodule Magus.Organizations.OrganizationRolesTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Organizations

  defp make_org_with_member do
    owner = generate(user())
    ensure_workspace_plan(owner)

    {:ok, org} =
      Organizations.create_organization(
        %{name: "Org", slug: "org-#{System.unique_integer([:positive])}"},
        actor: owner
      )

    member_user = generate(user())

    member =
      Magus.Organizations.OrganizationMember
      |> Ash.Changeset.for_create(:create_member, %{
        organization_id: org.id,
        user_id: member_user.id,
        invite_email: member_user.email
      })
      |> Ash.create!(authorize?: false)

    %{owner: owner, org: org, member: member, member_user: member_user}
  end

  test "owner can remove a member" do
    %{owner: owner, member: member} = make_org_with_member()
    {:ok, removed} = Organizations.remove_org_member(member, actor: owner)
    assert removed.status == :removed
    assert removed.removed_at != nil
  end

  test "cannot remove the last owner" do
    %{owner: owner, org: org} = make_org_with_member()
    {:ok, members} = Organizations.list_org_members(org.id, actor: owner)
    owner_member = Enum.find(members, &(&1.role == :owner))

    assert {:error, error} = Organizations.remove_org_member(owner_member, actor: owner)
    assert Exception.message(error) =~ "last owner"
  end

  test "transfer ownership promotes target and demotes actor" do
    %{owner: owner, org: org, member: member} = make_org_with_member()
    {:ok, promoted} = Organizations.transfer_org_ownership(member, actor: owner)
    assert promoted.role == :owner

    {:ok, reloaded_org} = Organizations.get_organization(org.id, actor: owner)
    assert reloaded_org.owner_id == member.user_id

    {:ok, members} = Organizations.list_org_members(org.id, actor: owner)
    old_owner = Enum.find(members, &(&1.user_id == owner.id))
    assert old_owner.role == :member
  end
end
