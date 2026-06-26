defmodule MagusWeb.JobsLive.Helpers do
  @moduledoc """
  Shared helper functions for Jobs LiveView components.
  """

  @doc """
  Formats a datetime for display, converting to the user's timezone.

  Returns a short format like "Jan 15, 14:30".
  """
  def format_datetime(nil, _timezone), do: "-"

  def format_datetime(dt, timezone) do
    tz = timezone || "UTC"

    case DateTime.shift_zone(dt, tz) do
      {:ok, shifted} -> Calendar.strftime(shifted, "%b %d, %H:%M")
      _ -> Calendar.strftime(dt, "%b %d, %H:%M UTC")
    end
  end

  @doc """
  Formats a datetime with full date and timezone for display.

  Returns a format like "Jan 15, 2025 14:30 UTC".
  """
  def format_datetime_full(nil, _timezone), do: "-"

  def format_datetime_full(dt, timezone) do
    tz = timezone || "UTC"

    case DateTime.shift_zone(dt, tz) do
      {:ok, shifted} -> Calendar.strftime(shifted, "%b %d, %Y %H:%M %Z")
      _ -> Calendar.strftime(dt, "%b %d, %Y %H:%M UTC")
    end
  end

  @doc """
  Formats a cron expression into a human-readable description.
  """
  def describe_cron(cron) do
    case String.split(cron) do
      ["0", h, "*", "*", "*"] ->
        "Daily at #{h}:00"

      ["0", h, "*", "*", "1-5"] ->
        "Weekdays at #{h}:00"

      ["0", h, "*", "*", "0,6"] ->
        "Weekends at #{h}:00"

      [m, h, "*", "*", "*"] ->
        "Daily at #{h}:#{String.pad_leading(m, 2, "0")}"

      _ ->
        cron
    end
  end

  @doc """
  Formats a duration between two DateTimes as a human-readable string.
  """
  def format_duration(started, completed) do
    seconds = DateTime.diff(completed, started, :second)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      true -> "#{div(seconds, 3600)}h"
    end
  end
end
