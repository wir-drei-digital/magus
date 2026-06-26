defmodule Magus.Usage.MeteringSinkTest do
  @moduledoc """
  Core (Billing-free) coverage of the `Magus.Usage.MeteringSink` seam: the Noop
  default and the dispatcher. The billing-edition impl (which enqueues
  `Magus.Billing.Workers.ReportMeterEvent`) is covered separately in
  `test/magus/billing/metering_sink_test.exs`.
  """
  # async: false — flips the configured sink impl process-globally and exercises
  # Oban enqueue assertions (DB sandbox), so it must not run concurrently with
  # tests reading the same config or the jobs table.
  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  alias Magus.Usage.MeteringSink

  describe "with the Noop default configured" do
    setup do
      previous = Application.get_env(:magus, MeteringSink)
      Application.put_env(:magus, MeteringSink, impl: MeteringSink.Noop)

      on_exit(fn ->
        if previous do
          Application.put_env(:magus, MeteringSink, previous)
        else
          Application.delete_env(:magus, MeteringSink)
        end
      end)

      :ok
    end

    test "report_charge/1 returns :ok and enqueues nothing" do
      charge = %MeteringSink.Charge{
        user_id: "u",
        overflow_cents: 42,
        identifier: "usage-noop",
        stripe_customer_id: "cus_1",
        stripe_subscription_id: "sub_1"
      }

      assert MeteringSink.report_charge(charge) == :ok
      assert all_enqueued() == []
    end

    test "configured?/0 returns false" do
      refute MeteringSink.configured?()
    end
  end
end
