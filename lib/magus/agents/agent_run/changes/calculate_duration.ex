defmodule Magus.Agents.AgentRun.Changes.CalculateDuration do
  @moduledoc """
  Calculates duration_ms from started_at to now on terminal status transitions.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    started_at = Ash.Changeset.get_attribute(changeset, :started_at)

    if started_at do
      duration = DateTime.diff(DateTime.utc_now(), started_at, :millisecond)
      Ash.Changeset.change_attribute(changeset, :duration_ms, duration)
    else
      changeset
    end
  end
end
