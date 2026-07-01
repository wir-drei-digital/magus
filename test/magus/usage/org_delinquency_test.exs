defmodule Magus.Usage.OrgDelinquencyTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Usage.Calculator

  defp org_sponsored_member(billing_status) do
    owner = generate(user())
    ensure_workspace_plan(owner)
    member = generate(user())
    ensure_workspace_plan(member)

    {:ok, org} =
      Magus.Organizations.create_organization(
        %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
        actor: owner
      )

    org
    |> Ash.Changeset.for_update(
      :set_billing,
      %{
        stripe_subscription_id: "sub_org_#{System.unique_integer([:positive])}",
        billing_status: billing_status
      },
      authorize?: false
    )
    |> Ash.update!()

    {:ok, sub} = Magus.Usage.get_user_subscription(member.id, authorize?: false)
    {:ok, _} = Magus.Usage.set_sponsor_org(sub, %{sponsor_org_id: org.id}, authorize?: false)
    %{member: member, org: org}
  end

  test "member of a past_due org is delinquent" do
    %{member: member} = org_sponsored_member(:past_due)
    assert Calculator.get_spend_state(member.id).delinquent == true
  end

  test "member of an active org is not delinquent" do
    %{member: member} = org_sponsored_member(:active)
    assert Calculator.get_spend_state(member.id).delinquent == false
  end

  test "personal past_due path still blocks (regression)" do
    user = generate(user())
    ensure_workspace_plan(user)
    {:ok, sub} = Magus.Usage.get_user_subscription(user.id, authorize?: false)

    sub
    |> Ash.Changeset.for_update(
      :upgrade,
      %{
        stripe_customer_id: "cus_x",
        stripe_subscription_id: "sub_personal_1",
        status: :active,
        usage_plan_id: sub.usage_plan_id
      },
      authorize?: false
    )
    |> Ash.update!()

    {:ok, sub} = Magus.Usage.get_user_subscription(user.id, authorize?: false)

    {:ok, _} =
      Magus.Usage.update_subscription_from_stripe(sub, %{status: :past_due}, authorize?: false)

    assert Calculator.get_spend_state(user.id).delinquent == true
  end
end
