defmodule Magus.LiveE2E.EventDrivenWakeTest do
  @moduledoc """
  Live E2E smoke test for the event-driven autonomy foundation
  (docs/superpowers/specs/2026-07-03-event-driven-agent-autonomy-design.md):

      create AgentInboxEvent (urgency: :immediate)
        -> TriggerUrgentWake enqueues an AgentRun (source: :inbox_urgent)
           WITHOUT any heartbeat tick
        -> ConversationAgent wakes on the home conversation with the
           urgent wakeup preamble
        -> real LLM turn via OpenRouter (liveness pings fire from the
           streaming/tool plugins during the turn)
        -> AgentRunCompletionPlugin completes the run, resolves the
           triggering event via the run linkage, and schedules the
           fallback heartbeat
        -> AutonomyTrace + telemetry record the wake

  This verifies the Phase 1-3 pieces working together against the real
  pipeline, which the unit suites cover only in isolation.
  """
  use Magus.LiveE2ECase, async: false

  require Ash.Query

  alias Magus.Agents.AgentInboxEvent
  alias Magus.Agents.AgentRun
  alias Magus.Agents.Support.HomeConversation

  @moduletag :autonomy
  @moduletag timeout: 240_000

  describe "urgent inbox event wake" do
    test "immediate event wakes the agent end-to-end without a heartbeat tick", %{user: user} do
      handler_id = "e2e-wake-telemetry-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach_many(
        handler_id,
        [
          [:magus, :agents, :wake, :urgent],
          [:magus, :agents, :run, :completed]
        ],
        fn event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, agent} =
        Magus.Agents.create_custom_agent(
          %{
            name: "UrgentWakeBot #{System.unique_integer([:positive])}",
            instructions:
              "You are an autonomous test agent. When you wake up, use the TOOL CALLING " <>
                "API (function calls) to invoke `list_inbox_events` (no arguments), then " <>
                "reply with a one-sentence summary of the most urgent event in your inbox. " <>
                "Do not search memories. Keep the reply short.",
            heartbeat_enabled: true,
            heartbeat_default_interval_minutes: 60,
            # Far-future schedule: proves the wake below cannot come from the
            # heartbeat scheduler (which we never tick anyway).
            next_scheduled_at: DateTime.add(DateTime.utc_now(), 7 * 24 * 3600, :second),
            max_daily_runs: 10,
            max_iterations: 8
          },
          actor: user
        )

      {:ok, home} = HomeConversation.ensure(user.id, agent.id)
      subscribe_to_agent(home.id)

      # The event-driven trigger: creating the :immediate event IS the wake.
      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :task_assigned,
            urgency: :immediate,
            title: "URGENT: production log source reports repeated crash signature",
            summary: "Summarize this event back to your owner in one sentence.",
            source_type: :system,
            source_id: "e2e-urgent-source"
          },
          actor: user
        )

      assert_response_complete(180_000)
      drain_signals()

      # Exactly one :inbox_urgent run, keyed to the event, completed.
      runs =
        AgentRun
        |> Ash.Query.filter(target_agent_id == ^agent.id and source == :inbox_urgent)
        |> Ash.read!(authorize?: false)

      assert length(runs) == 1, "Expected exactly one :inbox_urgent AgentRun"
      [run] = runs

      assert run.status == :complete,
             "Expected AgentRun :complete, got #{inspect(run.status)} (error: #{inspect(run.error_message)})"

      assert run.idempotency_key == "inbox:#{event.id}"
      assert run.target_conversation_id == home.id

      # Phase 2 liveness: the streaming/tool plugins must have pinged
      # last_heartbeat_at during the turn, so it is strictly newer than the
      # claim-time value (claim sets started_at == last_heartbeat_at).
      assert DateTime.compare(run.last_heartbeat_at, run.started_at) == :gt,
             "Expected liveness pings during the turn " <>
               "(last_heartbeat_at #{inspect(run.last_heartbeat_at)} vs started_at #{inspect(run.started_at)})"

      # The triggering event resolves through the run linkage.
      reloaded_event = Ash.get!(AgentInboxEvent, event.id, authorize?: false)

      assert reloaded_event.status == :resolved,
             "Expected the urgent event resolved via run completion, got #{inspect(reloaded_event.status)}"

      assert reloaded_event.resolved_by == :run_completed

      # ensure_next_scheduled_at applies to :inbox_urgent runs: the far-future
      # schedule is either untouched (still future) or replaced; it must never
      # be left nil or in the past.
      {:ok, reloaded_agent} = Magus.Agents.get_custom_agent(agent.id, authorize?: false)
      refute is_nil(reloaded_agent.next_scheduled_at)
      assert DateTime.compare(reloaded_agent.next_scheduled_at, DateTime.utc_now()) == :gt

      # Trace message in the home conversation (HeartbeatEventMessage with
      # source inbox_urgent).
      event_messages =
        Magus.Chat.Message
        |> Ash.Query.filter(conversation_id == ^home.id and message_type == :event)
        |> Ash.read!(authorize?: false)

      assert Enum.any?(event_messages, fn msg ->
               get_in(msg.metadata || %{}, ["source"]) == "inbox_urgent"
             end),
             "Expected an inbox_urgent trace event message in the home conversation"

      # Phase 3 observability: activity-log entry + telemetry both fired.
      activity =
        Magus.Agents.AgentActivityLog
        |> Ash.Query.filter(agent_id == ^agent.id and activity_type == :wake_urgent)
        |> Ash.read!(authorize?: false)

      assert length(activity) == 1, "Expected exactly one :wake_urgent activity entry"

      assert_received {:telemetry, [:magus, :agents, :wake, :urgent], wake_meta}
      assert wake_meta.target_agent_id == agent.id

      assert_received {:telemetry, [:magus, :agents, :run, :completed], _run_meta}
    end
  end
end
