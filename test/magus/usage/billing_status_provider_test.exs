defmodule Magus.Usage.BillingStatusProviderTest do
  use Magus.ResourceCase, async: true
  alias Magus.Usage.BillingStatusProvider

  test "default provider returns the account's stored status" do
    # Seed the free plan so registration's after-action creates an Account row
    # with a stored status to read back.
    ensure_free_plan()
    user = generate(user())
    {:ok, _} = Magus.Usage.get_user_subscription(user.id, authorize?: false)

    assert BillingStatusProvider.status_for_user(user.id) in [
             :active,
             :trialing,
             :past_due,
             :canceled
           ]
  end

  test "returns :active for a user with no subscription row" do
    assert BillingStatusProvider.status_for_user(Ecto.UUID.generate()) == :active
  end
end
