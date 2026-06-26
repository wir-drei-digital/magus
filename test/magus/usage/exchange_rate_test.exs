defmodule Magus.Usage.ExchangeRateTest do
  @moduledoc """
  Tests for `Magus.Usage.ExchangeRate`, the USD -> internal-cost-unit exchange
  rate seam. Core defaults to the 1:1 `Identity` (no process); the billing
  edition wires a process-backed source (`Magus.Billing.FxRates`).
  """
  # async: false — flips the global :magus, Magus.Usage.ExchangeRate impl config.
  use ExUnit.Case, async: false

  alias Magus.Usage.ExchangeRate

  # A process-backed fake impl (has child_spec/1 via `use GenServer`).
  defmodule FakeRateServer do
    use GenServer
    @behaviour Magus.Usage.ExchangeRate

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl GenServer
    def init(state), do: {:ok, state}

    @impl Magus.Usage.ExchangeRate
    def usd_to_chf, do: Decimal.new("0.9")
  end

  setup do
    original = Application.get_env(:magus, ExchangeRate)

    on_exit(fn ->
      if original do
        Application.put_env(:magus, ExchangeRate, original)
      else
        Application.delete_env(:magus, ExchangeRate)
      end
    end)
  end

  describe "Identity default (open-core, no billing configured)" do
    setup do
      Application.delete_env(:magus, ExchangeRate)
      :ok
    end

    test "usd_to_chf/0 returns the 1:1 rate" do
      assert Decimal.equal?(ExchangeRate.usd_to_chf(), Decimal.new(1))
    end

    test "child_specs/0 is empty (the Identity impl needs no process)" do
      assert ExchangeRate.child_specs() == []
    end
  end

  describe "configured process-backed impl (billing edition)" do
    setup do
      Application.put_env(:magus, ExchangeRate, impl: FakeRateServer)
      :ok
    end

    test "usd_to_chf/0 delegates to the configured impl" do
      assert Decimal.equal?(ExchangeRate.usd_to_chf(), Decimal.new("0.9"))
    end

    test "child_specs/0 supervises the process-backed impl" do
      assert ExchangeRate.child_specs() == [FakeRateServer]
    end
  end
end
