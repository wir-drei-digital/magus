defmodule Magus.Usage.ExchangeRate do
  @moduledoc """
  USD -> internal-cost-unit (CHF) exchange-rate seam for the open-core split.

  Provider costs (e.g. OpenRouter) are in USD; usage governance accounts in
  internal cost-unit cents. Core ships a 1:1 `Identity` default (no live FX, no
  process), so a self-host instance needs no exchange-rate service and never
  names the billing edition. The combined/cloud app wires a process-backed
  source (`Magus.Billing.FxRates`, hourly Stripe FX) via:

      config :magus, Magus.Usage.ExchangeRate, impl: Magus.Billing.FxRates

  The hot conversion paths (`PolicyEnforcer` estimates, `UsageRecorder`
  draw-down, `MessageUsageLog` display) call `usd_to_chf/0`. Supervision is
  delegated through `child_specs/0`: a process-backed impl is supervised by
  core's application tree; the `Identity` default contributes no child.
  """

  @doc "The current USD -> internal-cost-unit rate as a `Decimal`."
  @callback usd_to_chf() :: Decimal.t()

  @doc "The configured exchange-rate impl (default: the 1:1 `Identity`)."
  @spec impl() :: module()
  def impl, do: Application.get_env(:magus, __MODULE__, [])[:impl] || __MODULE__.Identity

  @doc "Current USD -> internal-cost-unit rate via the configured impl."
  @spec usd_to_chf() :: Decimal.t()
  def usd_to_chf, do: impl().usd_to_chf()

  @doc """
  Child specs for the supervision tree: the configured impl if it is a process
  (exports `child_spec/1`), else none. Core's application supervisor splices
  this in, so the billing edition's FX refresher is supervised without core
  naming it.
  """
  @spec child_specs() :: [module()]
  def child_specs do
    mod = impl()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :child_spec, 1) do
      [mod]
    else
      []
    end
  end

  defmodule Identity do
    @moduledoc "Default 1:1 exchange rate for open-core (no live FX)."
    @behaviour Magus.Usage.ExchangeRate

    @impl true
    def usd_to_chf, do: Decimal.new(1)
  end
end
