defmodule Magus.Agents.CustomAgent.Changes.WatchdogReset do
  @moduledoc """
  Oban-triggered change that self-heals an overdue heartbeat schedule.

  An agent is a watchdog candidate when it's `heartbeat_enabled`, not
  `is_paused`, and its `next_scheduled_at` is more than 2x its
  `heartbeat_default_interval_minutes` in the past (see
  `CustomAgent.is_watchdog_overdue`, which gates the Oban trigger). This
  normally shouldn't happen — `HeartbeatScheduler` advances the schedule on
  every tick outcome — so an overdue agent here means that advance was lost
  somewhere (e.g. a crashed scheduler tick, a node restart mid-dispatch).

  Resets `next_scheduled_at` to now so the next heartbeat sweep picks the
  agent back up, logs a `Logger.warning`, and writes a `:watchdog_reset`
  `AgentActivityLog` entry via `AutonomyTrace.log/5` so the reset is visible
  to the user, not just the server log.
  """

  use Ash.Resource.Change

  require Logger

  alias Magus.Agents.Support.AutonomyTrace

  @impl true
  def change(changeset, _opts, _context) do
    old_next_scheduled_at = changeset.data.next_scheduled_at

    changeset
    |> Ash.Changeset.force_change_attribute(:next_scheduled_at, DateTime.utc_now())
    |> Ash.Changeset.after_action(fn _changeset, agent ->
      Logger.warning(
        "WatchdogReset: agent #{agent.id} heartbeat schedule was overdue; reset next_scheduled_at " <>
          "(was #{inspect(old_next_scheduled_at)})"
      )

      AutonomyTrace.log(
        agent.id,
        agent.user_id,
        :watchdog_reset,
        "Watchdog reset overdue heartbeat schedule",
        %{was: old_next_scheduled_at}
      )

      {:ok, agent}
    end)
  end
end
