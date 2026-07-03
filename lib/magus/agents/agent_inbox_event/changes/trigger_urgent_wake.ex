defmodule Magus.Agents.AgentInboxEvent.Changes.TriggerUrgentWake do
  @moduledoc """
  Wakes the owning agent when an `:immediate` inbox event is created.

  Enqueues an `:inbox_urgent` AgentRun through the standard orchestrator
  gates. Runs in `after_transaction` so agent dispatch never happens inside
  the event's insert transaction. Never fails event creation: every error
  path logs and returns the event unchanged.

  Skips: `:deferred` events, paused or heartbeat-disabled agents, and events
  created with `agent_run_id` already set (pre-linked by an in-flight run).
  One urgent run per event, ever: the `"inbox:<event_id>"` idempotency key
  makes replays and post-failure retries no-ops; an unhandled event falls
  back to the next heartbeat.

  ## Nested-transaction deferral

  When the event is created inside a still-open parent transaction (e.g.
  `Magus.Plan.Task` update → `NotifyAgentAssignment` after_action →
  `create_inbox_event`), Ash starts no new transaction for the nested create,
  so this `after_transaction` hook runs synchronously *inside* the outer
  transaction. Enqueuing there would write an `AgentRun` and dispatch the
  agent before the outer transaction commits: if a later step rolls back, the
  event and run vanish but the agent was already dispatched (phantom run), and
  during the window the in-flight gate wrongly blocks legitimate enqueues.

  To guarantee we only wake for *committed* events, when
  `Ash.DataLayer.in_transaction?/1` is true we defer: a supervised async task
  polls (outside the transaction) for the committed event and runs the wake
  only once the event is durably visible, still unlinked, and pending/waiting.
  If the outer transaction rolls back the event never appears and no wake
  fires. Outside a transaction the wake runs synchronously as before.
  """

  use Ash.Resource.Change

  require Logger

  alias Magus.Agents.AgentInboxEvent
  alias Magus.Agents.HeartbeatEventMessage
  alias Magus.Agents.RunOrchestrator
  alias Magus.Agents.Support.AutonomyTrace
  alias Magus.Agents.Support.HomeConversation

  @poll_attempts 10
  @poll_interval_ms 200

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, event} ->
        maybe_wake(event)
        {:ok, event}

      _changeset, error ->
        error
    end)
  end

  defp maybe_wake(%{urgency: :immediate, agent_run_id: nil} = event) do
    if Ash.DataLayer.in_transaction?(AgentInboxEvent) do
      defer_wake(event)
    else
      do_wake(event)
    end
  end

  defp maybe_wake(_event), do: :ok

  # Inside an open outer transaction: the event row is not yet committed and a
  # later after_action could still roll it back. Hand off to a supervised task
  # that polls for the committed event before waking. Never fails event
  # creation: if the supervisor is unavailable the event falls back to the next
  # heartbeat pickup.
  defp defer_wake(event) do
    Logger.debug(
      "TriggerUrgentWake: deferring wake for event #{event.id} (created in transaction)"
    )

    Task.Supervisor.start_child(Magus.AgentLoopTaskSupervisor, fn ->
      poll_and_wake(event.id, @poll_attempts)
    end)

    :ok
  rescue
    e ->
      Logger.warning(
        "TriggerUrgentWake: could not defer wake for event #{event.id} (falls back to heartbeat): #{Exception.message(e)}"
      )

      :ok
  catch
    :exit, reason ->
      Logger.warning(
        "TriggerUrgentWake: could not defer wake for event #{event.id} (falls back to heartbeat): #{inspect(reason)}"
      )

      :ok
  end

  defp poll_and_wake(_event_id, 0), do: :ok

  defp poll_and_wake(event_id, attempts_left) do
    case Ash.get(AgentInboxEvent, event_id, authorize?: false) do
      {:ok, %{agent_run_id: nil, status: status} = event} when status in [:pending, :waiting] ->
        do_wake(event)

      {:ok, _event} ->
        # Event committed but already linked or no longer pending: nothing to do.
        :ok

      {:error, _} ->
        Process.sleep(@poll_interval_ms)
        poll_and_wake(event_id, attempts_left - 1)
    end
  rescue
    e ->
      Logger.warning(
        "TriggerUrgentWake: deferred wake failed for event #{event_id}: #{Exception.message(e)}"
      )

      :ok
  end

  defp do_wake(%{agent_id: agent_id} = event) do
    with {:ok, agent} <- Ash.get(Magus.Agents.CustomAgent, agent_id, authorize?: false),
         true <- agent.heartbeat_enabled and not agent.is_paused,
         {:ok, home} <- HomeConversation.ensure(agent.user_id, agent.id) do
      enqueue(event, agent, home)
    else
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning(
        "TriggerUrgentWake: wake failed for event #{event.id}: #{Exception.message(e)}"
      )

      :ok
  end

  defp enqueue(event, agent, home) do
    attrs = %{
      kind: :delegate,
      source: :inbox_urgent,
      source_conversation_id: home.id,
      target_conversation_id: home.id,
      target_agent_id: agent.id,
      initiator_user_id: agent.user_id,
      request_id: "inbox-urgent-#{Ash.UUID.generate()}",
      idempotency_key: "inbox:#{event.id}",
      objective: "Urgent inbox event: #{event.title}"
    }

    case RunOrchestrator.enqueue_with_outcome(attrs) do
      {:ok, :created, run} ->
        link_event(event, run)
        trace(home.id, run)

        AutonomyTrace.log(
          agent.id,
          agent.user_id,
          :wake_urgent,
          "Urgent wake for inbox event: #{event.title}",
          %{event_id: event.id}
        )

      {:ok, :existing, _run} ->
        :ok

      {:error, :already_running} ->
        # Drained by AgentRunCompletionPlugin when the in-flight run finishes.
        :ok

      {:error, reason} when reason in [:budget_exceeded, :insufficient_spend_budget] ->
        Logger.info("TriggerUrgentWake: skipped (#{reason}) for event #{event.id}")

        AutonomyTrace.log(
          agent.id,
          agent.user_id,
          :wake_skipped,
          "Urgent wake skipped for inbox event: #{event.title}",
          %{reason: to_string(reason), event_id: event.id}
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "TriggerUrgentWake: enqueue failed for event #{event.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp link_event(event, run) do
    case Magus.Agents.link_event_to_run(event, run.id, authorize?: false) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "TriggerUrgentWake: failed to link event #{event.id} to run #{run.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp trace(home_id, run) do
    case HeartbeatEventMessage.create(home_id, run_id: run.id, source: :inbox_urgent) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("TriggerUrgentWake: trace message failed: #{inspect(reason)}")
        :ok
    end
  end
end
