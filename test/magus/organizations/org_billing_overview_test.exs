defmodule Magus.Organizations.OrgBillingOverviewTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  test "owner gets a billing overview; not-set-up when no stripe sub" do
    owner = generate(user())
    ensure_workspace_plan(owner)

    {:ok, org} =
      Magus.Organizations.create_organization(
        %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
        actor: owner
      )

    {:ok, ov} = Magus.Organizations.org_billing_overview(%{organization_id: org.id}, actor: owner)
    assert ov.billing_status == "active"
    assert ov.billing_set_up == false
    assert ov.seat_count == 1
    assert is_boolean(ov.billing_edition)
  end

  test "a non-owner member is forbidden" do
    owner = generate(user())
    ensure_workspace_plan(owner)
    m1 = generate(user())
    ensure_workspace_plan(m1)

    {:ok, org} =
      Magus.Organizations.create_organization(
        %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
        actor: owner
      )

    {:ok, _} =
      Magus.Organizations.OrganizationMember
      |> Ash.Changeset.for_create(
        :create_member,
        %{organization_id: org.id, user_id: m1.id, invite_email: to_string(m1.email)},
        authorize?: false
      )
      |> Ash.create(authorize?: false)

    assert {:error, %Ash.Error.Forbidden{}} =
             Magus.Organizations.org_billing_overview(%{organization_id: org.id}, actor: m1)
  end
end
