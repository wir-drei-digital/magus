defmodule Magus.Usage.AccountLifecycleTest do
  use ExUnit.Case, async: true
  alias Magus.Usage.AccountLifecycle

  describe "core no-op default" do
    test "on_deletion is a no-op returning :ok" do
      assert AccountLifecycle.Noop.on_deletion("user-id") == :ok
    end

    test "on_registration is a no-op returning :ok" do
      assert AccountLifecycle.Noop.on_registration("user-id") == :ok
    end
  end

  describe "dispatcher" do
    # The combined app wires `impl: Magus.Billing.AccountLifecycle` in config.
    # No call site invokes these yet (the swap is Task 5), but the dispatcher
    # must resolve and route without error.
    test "on_registration dispatches and returns :ok" do
      assert AccountLifecycle.on_registration(Ecto.UUID.generate()) == :ok
    end

    test "on_deletion dispatches and returns :ok for a user with no Stripe subscription" do
      assert AccountLifecycle.on_deletion(Ecto.UUID.generate()) == :ok
    end
  end
end
