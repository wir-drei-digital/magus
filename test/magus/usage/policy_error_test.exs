defmodule Magus.Usage.PolicyErrorTest do
  use ExUnit.Case, async: true

  alias Magus.Usage.PolicyError

  test "carries structured data only" do
    err = %PolicyError{
      limit_type: :spend_cap,
      current: 2000,
      limit: 2000,
      upgrade_path: "/settings/subscription"
    }

    assert err.limit_type == :spend_cap
    assert err.current == 2000
    assert err.limit == 2000
    assert err.upgrade_path == "/settings/subscription"
  end

  test "is a proper exception with a non-user-facing fallback message" do
    err = PolicyError.exception(limit_type: :payment_required)

    msg = Exception.message(err)
    assert msg =~ "usage policy error: payment_required"
    assert msg =~ "Magus.Usage.PolicyErrorMessage"
    # The fallback must NOT contain the user-facing copy.
    refute msg =~ "payment method"
  end
end
