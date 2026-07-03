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
  """

  use Ash.Resource.Change

  require Logger

  alias Magus.Agents.HeartbeatEventMessage
  alias Magus.Agents.RunOrchestrator
  alias Magus.Agents.Support.HomeConversation

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
    with {:ok, agent} <- Ash.get(Magus.Agents.CustomAgent, event.agent_id, authorize?: false),
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

  defp maybe_wake(_event), do: :ok

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

      {:ok, :existing, _run} ->
        :ok

      {:error, :already_running} ->
        # Drained by AgentRunCompletionPlugin when the in-flight run finishes.
        :ok

      {:error, reason} when reason in [:budget_exceeded, :insufficient_spend_budget] ->
        Logger.info("TriggerUrgentWake: skipped (#{reason}) for event #{event.id}")
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
