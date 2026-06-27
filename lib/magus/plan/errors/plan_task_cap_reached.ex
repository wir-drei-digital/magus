defmodule Magus.Plan.Errors.PlanTaskCapReached do
  @moduledoc """
  Returned by `:create_plan` when a plan already holds `:max_open_tasks_per_plan`
  non-terminal (open/in_progress/blocked) tasks. A blunt backstop against runaway
  autonomous decomposition: a misbehaving agent gets a clear, catchable error and
  backs off instead of spiraling.

  Tagged `class: :invalid` so callers can pattern-match
  `%Ash.Error.Invalid{errors: [%__MODULE__{} | _]}`.
  """

  use Splode.Error, fields: [:brain_page_id, :cap], class: :invalid

  def message(%{cap: cap}), do: "plan has reached its open-task cap (#{cap})"
end
