defmodule Magus.Agents.Support.FailureStreak do
  @moduledoc """
  Escalates sustained autonomous-run failure: owner notification at exactly
  3 consecutive failures (exactly, so repeats don't spam), auto-pause with
  a visible reason at 10. A completed run resets the streak implicitly.

  Only autonomous sources count toward the streak (`:heartbeat`,
  `:manual_trigger`, `:inbox_urgent`) — `:mention` runs are user-driven
  conversations and shouldn't push an agent toward auto-pause.

  Runs are scanned newest-first by `completed_at`. Both `:fail` and
  `:timeout` set `completed_at` (see `agent_run.ex`), so this sort works
  for every terminal status considered here.
  """

  require Ash.Query
  require Logger

  alias Magus.Agents.Support.AutonomyTrace

  @autonomous_sources [:heartbeat, :manual_trigger, :inbox_urgent]
  @notify_at 3
  @pause_at 10
  @scan_limit 15

  @pause_reason "Auto-paused after 10 consecutive failed autonomous runs"

  @doc """
  Computes the consecutive-failure streak for `agent_id` and escalates:

    * exactly 3 consecutive failures -> notify the owner
    * >= 10 consecutive failures -> pause the agent (idempotent) + notify

  Returns `{:ok, streak}`. Never raises — any failure is logged and
  swallowed so a broken escalation path can't break the run lifecycle it's
  observing.
  """
  def check_and_escalate(nil), do: {:ok, 0}

  def check_and_escalate(agent_id) do
    runs =
      Magus.Agents.AgentRun
      |> Ash.Query.filter(
        target_agent_id == ^agent_id and
          source in ^@autonomous_sources and
          status in [:complete, :error, :timed_out]
      )
      |> Ash.Query.sort(completed_at: :desc)
      |> Ash.Query.limit(@scan_limit)
      |> Ash.read!(authorize?: false)

    streak = runs |> Enum.take_while(&(&1.status in [:error, :timed_out])) |> length()

    cond do
      streak >= @pause_at -> pause(agent_id, streak)
      streak == @notify_at -> notify(agent_id, streak)
      true -> :ok
    end

    {:ok, streak}
  rescue
    e ->
      Logger.warning("FailureStreak: check failed for #{agent_id}: #{Exception.message(e)}")
      {:ok, 0}
  end

  defp pause(agent_id, streak) do
    case Ash.get(Magus.Agents.CustomAgent, agent_id, authorize?: false) do
      {:ok, %{is_paused: true}} ->
        # Already paused (e.g. re-triggered by a later run in the same
        # streak, or a concurrent caller) — nothing left to do.
        :ok

      {:ok, agent} ->
        case Magus.Agents.pause_custom_agent_for_failures(agent, @pause_reason, authorize?: false) do
          {:ok, _paused} ->
            AutonomyTrace.log(
              agent_id,
              agent.user_id,
              :error,
              @pause_reason,
              %{streak: streak}
            )

            notify_owner(agent, streak, paused?: true)

          {:error, reason} ->
            Logger.warning("FailureStreak: failed to pause agent #{agent_id}: #{inspect(reason)}")

            :ok
        end

      {:error, reason} ->
        Logger.warning(
          "FailureStreak: could not load agent #{agent_id} to pause: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp notify(agent_id, streak) do
    case Ash.get(Magus.Agents.CustomAgent, agent_id, authorize?: false) do
      {:ok, agent} ->
        AutonomyTrace.log(
          agent_id,
          agent.user_id,
          :error,
          "#{streak} consecutive autonomous run failures",
          %{streak: streak}
        )

        notify_owner(agent, streak, paused?: false)

      {:error, reason} ->
        Logger.warning(
          "FailureStreak: could not load agent #{agent_id} to notify: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp notify_owner(agent, streak, paused?: paused?) do
    {title, body} =
      if paused? do
        {"Agent auto-paused", "#{agent.name} was auto-paused: #{@pause_reason}"}
      else
        {"Agent is failing repeatedly",
         "#{agent.name} has failed #{streak} autonomous runs in a row. " <>
           "It will be auto-paused after 10 consecutive failures."}
      end

    case Magus.Notifications.create_notification(
           %{
             user_id: agent.user_id,
             notification_type: :system,
             title: title,
             body: body,
             metadata: %{
               agent_id: agent.id,
               streak: streak,
               paused: paused?
             }
           },
           authorize?: false
         ) do
      {:ok, _notification} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "FailureStreak: failed to notify owner for agent #{agent.id}: #{inspect(reason)}"
        )

        :ok
    end
  end
end
