defmodule MagusWeb.Workbench.Live.Usage do
  @moduledoc """
  Computes pay-as-you-go usage data for the workbench mode strip: money spent
  this period (CHF), the effective monthly spend cap, and tokens
  used. Extracted from WorkbenchLive so the LV stays focused on orchestration.
  """

  alias Magus.Usage.Calculator

  # Warn the user once they've spent this share of their monthly cap.
  @near_cap_threshold 80.0

  @spec compute(map() | nil) :: map() | nil
  def compute(nil), do: nil

  def compute(user) do
    stats = Calculator.get_money_usage_stats(user.id)

    if stats.exempt do
      %{
        exempt: true,
        trial: false,
        delinquent: false,
        spent_cents: 0,
        cap_cents: nil,
        tokens_used: 0,
        percentage: 0,
        near_cap?: false
      }
    else
      # cap_cents is nil when the user opted out of the spend cap (postpaid).
      # `stats` already carries `delinquent` (from get_money_usage_stats); it is
      # preserved through the Map.put chain below.
      capped? = is_integer(stats.cap_cents) and stats.cap_cents > 0

      percentage =
        if capped?,
          do: Float.round(min(100.0, stats.spent_cents / stats.cap_cents * 100), 1),
          else: 0.0

      stats
      |> Map.put(:percentage, percentage)
      |> Map.put(:near_cap?, capped? and percentage >= @near_cap_threshold)
    end
  end
end
