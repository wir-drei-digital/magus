defmodule MagusWeb.ChatLive.Components.Tasks.DueDateHelpers do
  @moduledoc "Shared helpers for formatting and checking task due dates."

  def overdue?(nil), do: false

  def overdue?(due_at) do
    DateTime.compare(due_at, DateTime.utc_now()) == :lt
  end

  def format_due_date(nil), do: nil

  def format_due_date(due_at) do
    diff_days = DateTime.diff(due_at, DateTime.utc_now(), :day)

    cond do
      diff_days < 0 -> "#{abs(diff_days)}d overdue"
      diff_days == 0 -> "today"
      diff_days == 1 -> "tomorrow"
      diff_days <= 7 -> "in #{diff_days}d"
      true -> Calendar.strftime(due_at, "%b %d")
    end
  end
end
