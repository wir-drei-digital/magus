defmodule Magus.Organizations.LeaveOrgTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  test "a member leaves their own org" do
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

    {:ok, left} = Magus.Organizations.leave_org(member, actor: member_user)
    assert left.status == :removed
    assert %DateTime{} = left.removed_at
  end

  test "you cannot leave on behalf of another member" do
    owner = generate(user())
    ensure_workspace_plan(owner)
    m1 = generate(user())
    ensure_workspace_plan(m1)
    other = generate(user())
    ensure_workspace_plan(other)

    {:ok, org} =
      Magus.Organizations.create_organization(
        %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
        actor: owner
      )

    {:ok, member} =
      Magus.Organizations.OrganizationMember
      |> Ash.Changeset.for_create(
        :create_member,
        %{organization_id: org.id, user_id: m1.id, invite_email: to_string(m1.email)},
        authorize?: false
      )
      |> Ash.create(authorize?: false)

    assert {:error, %Ash.Error.Forbidden{}} =
             Magus.Organizations.leave_org(member, actor: other)
  end
end
