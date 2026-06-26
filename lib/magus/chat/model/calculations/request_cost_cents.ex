defmodule Magus.Chat.Model.Calculations.RequestCostCents do
  @moduledoc """
  Approximate CHF cents for a reference request (≈16k input + 4k output tokens)
  on this model, powering the composer model pickers' cost indicator.

  Delegates to `Magus.Usage.PolicyEnforcer.picker_request_cost_cents/1`
  so the workbench (LiveView) and SPA pickers share one calculation. Returns
  `nil` for image/video models, whose cost is per-image/second rather than
  token-based.
  """
  use Ash.Resource.Calculation

  alias Magus.Usage.PolicyEnforcer

  @impl true
  def load(_query, _opts, _context),
    do: [:input_cost_value, :output_cost_value, :output_cost_unit]

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, &PolicyEnforcer.picker_request_cost_cents/1)
  end
end
