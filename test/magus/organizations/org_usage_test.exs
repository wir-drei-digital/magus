defmodule Magus.Organizations.OrgUsageTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  test "owner sees pooled + all members; a member sees pooled + own only" do
    owner = generate(user())
    ensure_workspace_plan(owner)
    m1 = generate(user())
    ensure_workspace_plan(m1)

    {:ok, org} =
      Magus.Organizations.create_organization(
        %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
        actor: owner
      )

    {:ok, _member} =
      Magus.Organizations.OrganizationMember
      |> Ash.Changeset.for_create(
        :create_member,
        %{organization_id: org.id, user_id: m1.id, invite_email: to_string(m1.email)},
        authorize?: false
      )
      |> Ash.create(authorize?: false)

    # accrue some usage on m1
    {:ok, _sub} = Magus.Usage.get_user_subscription(m1.id, authorize?: false)
    Magus.Usage.deduct_usage(m1.id, 300, authorize?: false)

    {:ok, owner_view} =
      Magus.Organizations.org_usage_overview(%{organization_id: org.id}, actor: owner)

    assert owner_view.seat_count == 2
    assert owner_view.pooled_spent_cents >= 300
    assert length(owner_view.members) == 2

    {:ok, member_view} =
      Magus.Organizations.org_usage_overview(%{organization_id: org.id}, actor: m1)

    assert length(member_view.members) == 1
    assert hd(member_view.members).user_id == m1.id
  end

  test "a non-member cannot read org usage" do
    owner = generate(user())
    ensure_workspace_plan(owner)
    stranger = generate(user())
    ensure_workspace_plan(stranger)

    {:ok, org} =
      Magus.Organizations.create_organization(
        %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
        actor: owner
      )

    # The action policy only gates `actor_present()`; the real membership check
    # lives in `OrgUsage.for_organization`, whose `{:error, :forbidden}` surfaces
    # through the generic action as a wrapped `Ash.Error.Unknown`.
    assert {:error, %Ash.Error.Unknown{} = error} =
             Magus.Organizations.org_usage_overview(%{organization_id: org.id}, actor: stranger)

    assert Exception.message(error) =~ "forbidden"
  end
end
