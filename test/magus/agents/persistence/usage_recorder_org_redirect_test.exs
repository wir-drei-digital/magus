defmodule Magus.Agents.Persistence.UsageRecorderOrgRedirectTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  defmodule CaptureSink do
    @behaviour Magus.Usage.MeteringSink
    @impl true
    def report_charge(charge) do
      send(Application.get_env(:magus, :__capture_sink_pid__), {:charge, charge})
      :ok
    end
  end

  setup do
    prev = Application.get_env(:magus, Magus.Usage.MeteringSink)
    Application.put_env(:magus, :__capture_sink_pid__, self())
    Application.put_env(:magus, Magus.Usage.MeteringSink, impl: CaptureSink)

    on_exit(fn ->
      Application.put_env(:magus, Magus.Usage.MeteringSink, prev)
    end)

    :ok
  end

  test "org-sponsored member's usage meters to the org's Stripe customer + subscription" do
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
        stripe_customer_id: "cus_org_1",
        stripe_subscription_id: "sub_org_1",
        billing_status: :active
      },
      authorize?: false
    )
    |> Ash.update!()

    {:ok, sub} = Magus.Usage.get_user_subscription(member.id, authorize?: false)
    {:ok, _} = Magus.Usage.set_sponsor_org(sub, %{sponsor_org_id: org.id}, authorize?: false)

    :ok =
      Magus.Agents.Persistence.UsageRecorder.record_billable_cost(
        member.id,
        Decimal.new("1.00"),
        meter_identifier: "mu_test_1"
      )

    assert_receive {:charge,
                    %Magus.Usage.MeteringSink.Charge{
                      stripe_customer_id: "cus_org_1",
                      stripe_subscription_id: "sub_org_1"
                    }}
  end

  test "personal member's usage meters to their own Stripe customer" do
    user = generate(user())
    ensure_workspace_plan(user)
    {:ok, sub} = Magus.Usage.get_user_subscription(user.id, authorize?: false)

    sub
    |> Ash.Changeset.for_update(
      :upgrade,
      %{
        stripe_customer_id: "cus_personal_1",
        stripe_subscription_id: "sub_personal_1",
        status: :active,
        usage_plan_id: sub.usage_plan_id
      },
      authorize?: false
    )
    |> Ash.update!()

    :ok =
      Magus.Agents.Persistence.UsageRecorder.record_billable_cost(
        user.id,
        Decimal.new("1.00"),
        meter_identifier: "mu_test_2"
      )

    assert_receive {:charge,
                    %Magus.Usage.MeteringSink.Charge{
                      stripe_customer_id: "cus_personal_1",
                      stripe_subscription_id: "sub_personal_1"
                    }}
  end
end
