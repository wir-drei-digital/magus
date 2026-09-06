defmodule Magus.Usage.Account.Changes.ResetUsageOnPeriodChange do
  @moduledoc """
  Resets the metered usage accumulator when Stripe advances the billing period.

  Replayed webhook events for the current period and stale events for an older
  period leave the accumulator untouched.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    old_start = Ash.Changeset.get_data(changeset, :current_period_start)
    new_start = Ash.Changeset.get_attribute(changeset, :current_period_start)

    case period_change(old_start, new_start) do
      :advanced ->
        Ash.Changeset.force_change_attribute(changeset, :period_usage_cents, 0)

      :stale ->
        Ash.Changeset.force_change_attribute(changeset, :current_period_start, old_start)

      :unchanged ->
        changeset
    end
  end

  defp period_change(nil, %DateTime{}), do: :advanced

  defp period_change(%DateTime{} = old_start, %DateTime{} = new_start) do
    case DateTime.compare(new_start, old_start) do
      :gt -> :advanced
      :lt -> :stale
      :eq -> :unchanged
    end
  end

  defp period_change(_old_start, _new_start), do: :unchanged
end
