defmodule Magus.Agents.HeartbeatEventMessageTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Agents.HeartbeatEventMessage

  setup do
    user = generate(user())
    agent = custom_agent(user, %{})
    conv = generate(conversation(actor: user, custom_agent_id: agent.id))

    %{user: user, agent: agent, conv: conv}
  end

  test "creates an :event message with running text for heartbeat", %{conv: conv} do
    run_id = Ash.UUID.generate()

    {:ok, msg} =
      HeartbeatEventMessage.create(conv.id, run_id: run_id, source: :heartbeat)

    assert msg.message_type == :event
    assert msg.text =~ "Heartbeat started"
    assert msg.metadata["wakeup_run_id"] == run_id
    assert msg.metadata["wakeup_stage"] == "running"
    assert msg.metadata["source"] == "heartbeat"
  end

  test "omits wakeup_run_id when run_id is nil (skip-before-enqueue case)", %{conv: conv} do
    {:ok, msg} =
      HeartbeatEventMessage.create(conv.id, run_id: nil, source: :heartbeat)

    assert msg.message_type == :event
    refute Map.has_key?(msg.metadata, "wakeup_run_id")
    assert msg.metadata["wakeup_stage"] == "running"
    assert msg.metadata["source"] == "heartbeat"

    # Transitioning a nil-run skip event still works
    {:ok, updated} =
      HeartbeatEventMessage.transition(msg, :skipped_in_flight, %{})

    refute Map.has_key?(updated.metadata, "wakeup_run_id")
    assert updated.metadata["wakeup_stage"] == "skipped"
  end

  test "creates an :event message with running text for manual_trigger including user label",
       %{conv: conv} do
    run_id = Ash.UUID.generate()

    {:ok, msg} =
      HeartbeatEventMessage.create(conv.id,
        run_id: run_id,
        source: :manual_trigger,
        user_label: "Alice"
      )

    assert msg.message_type == :event
    assert msg.text =~ "Manual wake-up triggered by Alice"
    assert msg.metadata["source"] == "manual_trigger"
    assert msg.metadata["wakeup_stage"] == "running"
  end

  test "creates an :event message with running text for inbox_urgent", %{conv: conv} do
    run_id = Ash.UUID.generate()

    {:ok, msg} =
      HeartbeatEventMessage.create(conv.id, run_id: run_id, source: :inbox_urgent)

    assert msg.message_type == :event
    assert msg.text =~ ~r/urgent/i
    assert msg.metadata["wakeup_run_id"] == run_id
    assert msg.metadata["wakeup_stage"] == "running"
    assert msg.metadata["source"] == "inbox_urgent"
  end

  test "transitions to :complete with dismissed count and next_at", %{conv: conv} do
    {:ok, msg} =
      HeartbeatEventMessage.create(conv.id,
        run_id: Ash.UUID.generate(),
        source: :heartbeat
      )

    {:ok, updated} =
      HeartbeatEventMessage.transition(msg, :complete, %{
        dismissed: 2,
        next_at: ~U[2026-04-26 10:00:00Z]
      })

    assert updated.text =~ "Heartbeat completed"
    assert updated.text =~ "2"
    assert updated.metadata["wakeup_stage"] == "complete"
    # Existing metadata preserved
    assert updated.metadata["wakeup_run_id"] == msg.metadata["wakeup_run_id"]
    assert updated.metadata["source"] == "heartbeat"
  end

  test "transitions to :skipped_in_flight", %{conv: conv} do
    {:ok, msg} =
      HeartbeatEventMessage.create(conv.id,
        run_id: Ash.UUID.generate(),
        source: :heartbeat
      )

    {:ok, updated} = HeartbeatEventMessage.transition(msg, :skipped_in_flight, %{})

    assert updated.text =~ "previous wake-up"
    assert updated.metadata["wakeup_stage"] == "skipped"
  end

  test "transitions to :skipped_budget with usage", %{conv: conv} do
    {:ok, msg} =
      HeartbeatEventMessage.create(conv.id,
        run_id: Ash.UUID.generate(),
        source: :heartbeat
      )

    {:ok, updated} =
      HeartbeatEventMessage.transition(msg, :skipped_budget, %{used: 50, limit: 50})

    assert updated.text =~ "50/50"
    assert updated.metadata["wakeup_stage"] == "skipped"
  end

  test "transitions to :failed with error string", %{conv: conv} do
    {:ok, msg} =
      HeartbeatEventMessage.create(conv.id,
        run_id: Ash.UUID.generate(),
        source: :heartbeat
      )

    {:ok, updated} = HeartbeatEventMessage.transition(msg, :failed, %{error: "boom"})

    assert updated.text =~ "Heartbeat failed: boom"
    assert updated.metadata["wakeup_stage"] == "failed"
  end
end
