defmodule Magus.Agents.Workers.HeartbeatSchedulerTest do
  @moduledoc "Tests for the HeartbeatScheduler Oban cron worker."

  use Magus.DataCase, async: false

  import Magus.Generators

  require Ash.Query

  alias Magus.Agents.Workers.HeartbeatScheduler

  setup do
    free_plan = ensure_free_plan()
    %{free_plan: free_plan}
  end

  test "enqueues a heartbeat AgentRun for due agents" do
    user = generate(user())
    ensure_subscription(user)

    agent =
      custom_agent(user, %{
        heartbeat_enabled: true,
        heartbeat_default_interval_minutes: 360,
        next_scheduled_at: nil
      })

    :ok = HeartbeatScheduler.tick()

    runs =
      Magus.Agents.AgentRun
      |> Ash.Query.filter(target_agent_id == ^agent.id and source == :heartbeat)
      |> Ash.read!(authorize?: false)

    assert length(runs) == 1
    assert hd(runs).kind == :delegate
    assert hd(runs).source == :heartbeat
    assert hd(runs).initiator_user_id == user.id
  end

  test "skips agents that are paused" do
    user = generate(user())
    ensure_subscription(user)

    agent =
      custom_agent(user, %{
        heartbeat_enabled: true,
        is_paused: true,
        next_scheduled_at: nil
      })

    :ok = HeartbeatScheduler.tick()

    runs =
      Magus.Agents.AgentRun
      |> Ash.Query.filter(target_agent_id == ^agent.id)
      |> Ash.read!(authorize?: false)

    assert runs == []
  end

  test "skips agents with heartbeat_enabled: false" do
    user = generate(user())
    ensure_subscription(user)

    agent =
      custom_agent(user, %{
        heartbeat_enabled: false,
        next_scheduled_at: nil
      })

    :ok = HeartbeatScheduler.tick()

    runs =
      Magus.Agents.AgentRun
      |> Ash.Query.filter(target_agent_id == ^agent.id)
      |> Ash.read!(authorize?: false)

    assert runs == []
  end

  test "skips agents whose next_scheduled_at is still in the future" do
    user = generate(user())
    ensure_subscription(user)

    future = DateTime.utc_now() |> DateTime.add(3600, :second)

    agent =
      custom_agent(user, %{
        heartbeat_enabled: true,
        next_scheduled_at: future
      })

    :ok = HeartbeatScheduler.tick()

    runs =
      Magus.Agents.AgentRun
      |> Ash.Query.filter(target_agent_id == ^agent.id)
      |> Ash.read!(authorize?: false)

    assert runs == []
  end

  test "writes a skipped-in-flight event message when previous run is still running" do
    user = generate(user())
    ensure_subscription(user)

    agent =
      custom_agent(user, %{
        heartbeat_enabled: true,
        next_scheduled_at: nil
      })

    {:ok, home} = Magus.Agents.Support.HomeConversation.ensure(user.id, agent.id)

    {:ok, _existing_run} =
      Magus.Agents.create_agent_run(
        %{
          kind: :delegate,
          source: :heartbeat,
          source_conversation_id: home.id,
          target_conversation_id: home.id,
          target_agent_id: agent.id,
          initiator_user_id: user.id,
          request_id: "rid-pre-#{Ash.UUIDv7.generate()}",
          idempotency_key: "key-pre-#{Ash.UUIDv7.generate()}",
          objective: "x"
        },
        authorize?: false
      )

    {:ok, started} =
      Magus.Agents.start_agent_run(
        Magus.Agents.AgentRun
        |> Ash.Query.filter(target_agent_id == ^agent.id)
        |> Ash.read!(authorize?: false)
        |> List.first(),
        authorize?: false
      )

    assert started.status == :running

    :ok = HeartbeatScheduler.tick()

    messages =
      Magus.Chat.Message
      |> Ash.Query.filter(conversation_id == ^home.id and message_type == :event)
      |> Ash.read!(actor: user)

    assert Enum.any?(messages, fn m ->
             text = m.text || ""
             String.contains?(text, "skipped") or String.contains?(text, "Heartbeat skipped")
           end)

    # Schedule should have been advanced even though the enqueue was rejected.
    {:ok, reloaded_agent} = Magus.Agents.get_custom_agent(agent.id, authorize?: false)
    assert reloaded_agent.next_scheduled_at != nil
  end

  test "writes a :wake_skipped activity log entry when the daily run budget is exhausted" do
    user = generate(user())
    ensure_subscription(user)

    agent =
      custom_agent(user, %{
        heartbeat_enabled: true,
        next_scheduled_at: nil,
        max_daily_runs: 1
      })

    {:ok, home} = Magus.Agents.Support.HomeConversation.ensure(user.id, agent.id)

    # Pre-seed a completed heartbeat run today so the daily cap (1) is already
    # hit before the next tick runs.
    {:ok, existing_run} =
      Magus.Agents.create_agent_run(
        %{
          kind: :delegate,
          source: :heartbeat,
          source_conversation_id: home.id,
          target_conversation_id: home.id,
          target_agent_id: agent.id,
          initiator_user_id: user.id,
          request_id: "rid-budget-#{Ash.UUIDv7.generate()}",
          idempotency_key: "key-budget-#{Ash.UUIDv7.generate()}",
          objective: "x"
        },
        authorize?: false
      )

    {:ok, started} = Magus.Agents.start_agent_run(existing_run, authorize?: false)
    {:ok, _completed} = Magus.Agents.complete_agent_run(started, authorize?: false)

    :ok = HeartbeatScheduler.tick()

    logs =
      Magus.Agents.AgentActivityLog
      |> Ash.Query.for_read(:for_agent, %{agent_id: agent.id})
      |> Ash.read!(authorize?: false)

    assert Enum.any?(logs, fn log ->
             log.activity_type == :wake_skipped and
               log.summary == "Heartbeat skipped: daily run budget exhausted"
           end)
  end

  test "does not write a duplicate Heartbeat-started event message on idempotency replay" do
    user = generate(user())
    ensure_subscription(user)

    agent =
      custom_agent(user, %{
        heartbeat_enabled: true,
        # Long interval keeps the second tick inside the same window so the
        # idempotency key collides with the first run.
        heartbeat_default_interval_minutes: 360,
        next_scheduled_at: nil
      })

    # First tick creates the run and writes the visible "Heartbeat started"
    # event message.
    :ok = HeartbeatScheduler.tick()

    # Complete the run so the autonomous-run in-flight gate doesn't block the
    # second tick. After completion only the idempotency-key path can short
    # the second enqueue, which is exactly what we're testing.
    [run] =
      Magus.Agents.AgentRun
      |> Ash.Query.filter(target_agent_id == ^agent.id and source == :heartbeat)
      |> Ash.read!(authorize?: false)

    {:ok, _completed} =
      Magus.Agents.complete_agent_run(run, %{result_text: "ok"}, authorize?: false)

    # Force the agent to look due again without advancing the window so the
    # second tick collides with the same idempotency key.
    {:ok, agent_again} = Magus.Agents.get_custom_agent(agent.id, authorize?: false)

    {:ok, _} =
      agent_again
      |> Ash.Changeset.for_update(:clear_next_scheduled_at, %{})
      |> Ash.update(authorize?: false)

    :ok = HeartbeatScheduler.tick()

    {:ok, home} = Magus.Agents.Support.HomeConversation.ensure(user.id, agent.id)

    runs =
      Magus.Agents.AgentRun
      |> Ash.Query.filter(target_agent_id == ^agent.id and source == :heartbeat)
      |> Ash.read!(authorize?: false)

    # Idempotency must dedupe to a single AgentRun for this window.
    assert length(runs) == 1

    started_event_messages =
      Magus.Chat.Message
      |> Ash.Query.filter(conversation_id == ^home.id and message_type == :event)
      |> Ash.read!(actor: user)
      |> Enum.filter(fn m ->
        text = m.text || ""
        String.contains?(text, "Heartbeat started")
      end)

    # And the visible "Heartbeat started" trace message must NOT be
    # duplicated by the replay tick.
    assert length(started_event_messages) == 1
  end

  # Use the user's auto-created free subscription if present; otherwise create
  # one. RunOrchestrator's heartbeat spend-budget gate blocks users without any
  # available PAYG allowance. The free plan has a small trial allowance, enough
  # for a heartbeat tick.
  defp ensure_subscription(user) do
    case Magus.Usage.get_user_subscription(user.id, authorize?: false) do
      {:ok, _existing} ->
        :ok

      {:error, _} ->
        free_plan = ensure_free_plan()

        {:ok, _} =
          Magus.Usage.create_user_subscription(
            %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
            authorize?: false
          )

        :ok
    end
  end
end
