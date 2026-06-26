defmodule Magus.ReleaseTest do
  @moduledoc """
  `Magus.Release.provision_stripe/0` is a dynamic delegator to the billing
  edition's release module, so core compiles + boots without `Magus.Billing`
  (open-core split). A pure OSS install reports the edition is absent rather
  than failing to compile on the Stripe provisioning calls.
  """
  # async: false — reads/writes the global :magus, :billing_release_module app env.
  use ExUnit.Case, async: false

  setup do
    original = Application.get_env(:magus, :billing_release_module)

    on_exit(fn ->
      if original,
        do: Application.put_env(:magus, :billing_release_module, original),
        else: Application.delete_env(:magus, :billing_release_module)
    end)

    :ok
  end

  defmodule FakeBillingRelease do
    def provision_stripe, do: {:ok, :fake_provisioned}
  end

  describe "provision_stripe/0" do
    test "delegates to the configured billing-edition release module" do
      Application.put_env(:magus, :billing_release_module, FakeBillingRelease)

      assert Magus.Release.provision_stripe() == {:ok, :fake_provisioned}
    end

    test "reports the edition absent when the module is not loaded (pure OSS)" do
      Application.put_env(:magus, :billing_release_module, Magus.Does.Not.Exist)

      assert Magus.Release.provision_stripe() == {:error, :billing_edition_not_present}
    end
  end
end
