defmodule Magus.Agents.Workers.HeartbeatScheduler do
  @moduledoc """
  Polls for custom agents whose next heartbeat is due and enqueues an
  `AgentRun` (source: `:heartbeat`) via `RunOrchestrator`. On rejection,
  records a visible `:event` message in the home conversation and
  advances `next_scheduled_at` so the next tick can fire normally.

  This replaces the previous in-process triage dispatch path: heartbeat
  ticks now produce work units that flow through the same orchestration,
  preflight, and completion machinery as user-driven runs.
  """

  use Oban.Worker,
    queue: :heartbeat,
    max_attempts: 1

  require Ash.Query
  require Logger

  alias Magus.Agents.HeartbeatEventMessage
  alias Magus.Agents.RunOrchestrator
  alias Magus.Agents.Support.HomeConversation

  @default_heartbeat_interval_minutes 360

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: tick()

  @doc """
  Public entry point usable from tests.

  Reads all due heartbeat-eligible custom agents and enqueues an
  AgentRun for each. Always returns `:ok`; per-agent failures are
  logged and rescued to keep the cron stable.
  """
  def tick do
    list_due_agents()
    |> Enum.each(&process_agent/1)

    :ok
  end

  @doc """
  Returns custom agents whose heartbeat is currently due.

  An agent is due when:

    * `heartbeat_enabled` is true, and
    * `is_paused` is false, and
    * `next_scheduled_at` is `nil` or in the past.
  """
  def list_due_agents do
    now = DateTime.utc_now()

    Magus.Agents.CustomAgent
    |> Ash.Query.filter(
      heartbeat_enabled == true and
        is_paused == false and
        (is_nil(next_scheduled_at) or next_scheduled_at <= ^now)
    )
    |> Ash.read!(authorize?: false)
  end

  defp process_agent(agent) do
    with {:ok, user} <- Ash.get(Magus.Accounts.User, agent.user_id, authorize?: false),
         {:ok, home} <- HomeConversation.ensure(user.id, agent.id) do
      enqueue_for_agent(agent, user, home)
    else
      {:error, reason} ->
        Logger.warning(
          "HeartbeatScheduler: setup failed for agent #{agent.id}: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning(
        "HeartbeatScheduler: dispatch failed for #{agent.id}: #{Exception.message(e)}"
      )

      :ok
  end

  defp enqueue_for_agent(agent, user, home) do
    window = compute_window(agent)

    attrs = %{
      kind: :delegate,
      source: :heartbeat,
      source_conversation_id: home.id,
      target_conversation_id: home.id,
      target_agent_id: agent.id,
      initiator_user_id: user.id,
      request_id: "heartbeat-#{Ash.UUID.generate()}",
      idempotency_key: "heartbeat:#{agent.id}:#{window}",
      objective: agent.heartbeat_instructions || "Autonomous wake-up"
    }

    case RunOrchestrator.enqueue_with_outcome(attrs) do
      {:ok, :created, run} ->
        case HeartbeatEventMessage.create(home.id, run_id: run.id, source: :heartbeat) do
          {:ok, _msg} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "HeartbeatScheduler: failed to create event message for run #{run.id}: #{inspect(reason)}"
            )

            :ok
        end

      {:ok, :existing, run} ->
        # Idempotency-key replay: another tick (or a concurrent worker) already
        # created the run for this window. Don't write a duplicate "Heartbeat
        # started" trace message in the home conversation.
        Logger.debug(
          "HeartbeatScheduler: idempotency replay for run #{run.id}, skipping event message"
        )

        :ok

      {:error, :already_running} ->
        log_skip(home.id, :skipped_in_flight, %{})
        advance_schedule(agent)

      {:error, :budget_exceeded} ->
        log_skip(home.id, :skipped_budget, %{
          used: count_today(agent.id),
          limit: agent.max_daily_runs || 0
        })

        advance_schedule(agent)

      {:error, :insufficient_spend_budget} ->
        log_skip(home.id, :skipped_spend_budget, %{})
        advance_schedule(agent)

      {:error, reason} ->
        Logger.warning("HeartbeatScheduler: enqueue failed for #{agent.id}: #{inspect(reason)}")

        advance_schedule(agent)
    end
  end

  defp compute_window(agent) do
    interval_minutes =
      agent.heartbeat_default_interval_minutes || @default_heartbeat_interval_minutes

    interval_seconds = max(interval_minutes * 60, 60)
    div(System.system_time(:second), interval_seconds)
  end

  defp log_skip(home_id, stage, data) do
    case HeartbeatEventMessage.create(home_id, run_id: nil, source: :heartbeat) do
      {:ok, msg} ->
        case HeartbeatEventMessage.transition(msg, stage, data) do
          {:ok, _} -> :ok
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp count_today(agent_id) do
    window_start = DateTime.utc_now() |> DateTime.add(-86_400, :second)

    Magus.Agents.AgentRun
    |> Ash.Query.filter(
      target_agent_id == ^agent_id and source == :heartbeat and
        inserted_at >= ^window_start and status != :cancelled
    )
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp advance_schedule(agent) do
    interval_minutes =
      agent.heartbeat_default_interval_minutes || @default_heartbeat_interval_minutes

    next_at = DateTime.utc_now() |> DateTime.add(interval_minutes * 60, :second)

    case Magus.Agents.set_custom_agent_next_scheduled_at(agent, next_at, authorize?: false) do
      {:ok, _} ->
        :ok

      {:error, e} ->
        Logger.warning(
          "HeartbeatScheduler: advance_schedule failed for #{agent.id}: #{inspect(e)}"
        )

        :ok
    end
  end
end
