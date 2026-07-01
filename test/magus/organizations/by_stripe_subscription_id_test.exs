defmodule Magus.Organizations.ByStripeSubscriptionIdTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  test "looks up an org by its stripe_subscription_id" do
    user = generate(user())
    ensure_workspace_plan(user)

    {:ok, org} =
      Magus.Organizations.create_organization(
        %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
        actor: user
      )

    org
    |> Ash.Changeset.for_update(
      :set_billing,
      %{stripe_subscription_id: "sub_test_123", billing_status: :active},
      authorize?: false
    )
    |> Ash.update!()

    assert {:ok, found} =
             Magus.Organizations.get_organization_by_stripe_subscription_id("sub_test_123",
               authorize?: false
             )

    assert found.id == org.id

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
             Magus.Organizations.get_organization_by_stripe_subscription_id("sub_missing",
               authorize?: false
             )
  end
end
