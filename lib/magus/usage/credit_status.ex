defmodule Magus.Usage.CreditStatus do
  @moduledoc """
  Daily credit usage snapshot for a user: the shape behind the workbench
  mode-strip indicator (classic LiveView and the SvelteKit shell both render
  from this). Exempt users get a static all-clear.

  Pure usage governance: computed entirely from `Magus.Usage.Calculator`
  (storage + exemption), with no commercial-billing dependency. It lives in
  `Magus.Usage` so the open-core split keeps it in core (only `Magus.Billing`
  moves to the cloud edition).
  """

  alias Magus.Usage.Calculator

  @spec compute(map() | nil) :: map() | nil
  def compute(nil), do: nil

  # AI-agent actors carry a user_id but no id/timezone; credits are a
  # human-shell concern, so there is nothing to compute for them.
  def compute(%Magus.Agents.Support.AiAgent{}), do: nil

  def compute(user) do
    limits = Calculator.get_effective_limits(user.id)

    # Daily-credit metering was replaced by the pay-as-you-go spend model, so
    # the legacy daily-credits indicator no longer applies: `credits_limit: nil`
    # hides it in the shell (the SvelteKit indicator gates on it). Exempt state
    # and storage usage are still meaningful and surfaced here.
    %{
      exempt: limits[:exempt] == true,
      credits_used: 0,
      credits_limit: nil,
      percentage: 0,
      storage_used: Calculator.get_storage_used(user.id),
      storage_limit: limits[:storage_bytes]
    }
  end
end
