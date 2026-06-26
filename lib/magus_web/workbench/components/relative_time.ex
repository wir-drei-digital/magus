defmodule MagusWeb.Workbench.Components.RelativeTime do
  @moduledoc """
  Compact relative-time formatter for header chrome.

  Returns short strings like "5m ago" / "2h ago" / "3d ago", and falls back
  to a formatted date for anything older than a week. Returns `nil` for
  `nil` input so callers can safely interpolate without nil checks.
  """

  @spec relative(DateTime.t() | nil, DateTime.t()) :: String.t() | nil
  def relative(nil, _now), do: nil

  def relative(%DateTime{} = dt, %DateTime{} = now) do
    diff = DateTime.diff(now, dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%b %d, %Y")
    end
  end

  @spec relative(DateTime.t() | nil) :: String.t() | nil
  def relative(dt), do: relative(dt, DateTime.utc_now())
end
