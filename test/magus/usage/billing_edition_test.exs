defmodule Magus.Usage.BillingEditionTest do
  @moduledoc """
  `Magus.Usage.billing_edition?/0` is the explicit "commercial billing edition
  present" predicate, decoupled from `MeteringSink.configured?/0` (which only
  reports that metering is wired). Core UI gates on this without naming Billing.
  """
  # async: false — reads/writes the global :magus, :billing_edition? app env.
  use ExUnit.Case, async: false

  setup do
    original = Application.fetch_env(:magus, :billing_edition?)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:magus, :billing_edition?, value)
        :error -> Application.delete_env(:magus, :billing_edition?)
      end
    end)

    :ok
  end

  test "defaults to false when the flag is unset (pure OSS install)" do
    Application.delete_env(:magus, :billing_edition?)

    refute Magus.Usage.billing_edition?()
  end

  test "is true when the combined/cloud app sets the flag" do
    Application.put_env(:magus, :billing_edition?, true)

    assert Magus.Usage.billing_edition?()
  end

  test "is false when the flag is explicitly disabled" do
    Application.put_env(:magus, :billing_edition?, false)

    refute Magus.Usage.billing_edition?()
  end

  describe "billing_overview action plumbs the flag to the SPA" do
    test "includes billing_edition = false for an OSS install" do
      Application.put_env(:magus, :billing_edition?, false)

      input = Ash.ActionInput.for_action(Magus.Usage.Account, :billing_overview, %{})
      {:ok, overview} = Ash.run_action(input, authorize?: false)

      assert overview.billing_edition == false
    end

    test "includes billing_edition = true when the billing edition is present" do
      Application.put_env(:magus, :billing_edition?, true)

      input = Ash.ActionInput.for_action(Magus.Usage.Account, :billing_overview, %{})
      {:ok, overview} = Ash.run_action(input, authorize?: false)

      assert overview.billing_edition == true
    end
  end
end
