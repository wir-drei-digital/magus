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

    # accrue token usage on m1 (100 prompt + 100 completion per record)
    model = generate(model())
    create_usage_record(m1, model)
    create_usage_record(m1, model)

    {:ok, owner_view} =
      Magus.Organizations.org_usage_overview(%{organization_id: org.id}, actor: owner)

    assert owner_view.seat_count == 2
    assert owner_view.viewer_owner == true
    assert owner_view.pooled_spent_cents >= 300
    assert length(owner_view.members) == 2

    # tokens surface pooled + per member (2 records * 200 tokens = 400)
    assert owner_view.pooled_tokens == 400
    m1_row = Enum.find(owner_view.members, &(&1.user_id == m1.id))
    assert m1_row.tokens == 400
    owner_row = Enum.find(owner_view.members, &(&1.user_id == owner.id))
    assert owner_row.tokens == 0

    {:ok, member_view} =
      Magus.Organizations.org_usage_overview(%{organization_id: org.id}, actor: m1)

    assert member_view.viewer_owner == false
    assert length(member_view.members) == 1
    assert hd(member_view.members).user_id == m1.id
    assert hd(member_view.members).tokens == 400
    # pooled tokens stay visible to a non-owner member
    assert member_view.pooled_tokens == 400
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
    # lives in `OrgUsage.for_organization`, whose `Ash.Error.Forbidden` surfaces
    # through the generic action as a structured forbidden error (class
    # :forbidden), which the cloud RPC/e2e layer renders as "forbidden".
    assert {:error, %Ash.Error.Forbidden{} = error} =
             Magus.Organizations.org_usage_overview(%{organization_id: org.id}, actor: stranger)

    assert error.class == :forbidden
  end
end
