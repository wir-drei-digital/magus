defmodule Magus.Agents.Context.WakeupPreambleTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  alias Magus.Agents.Context.WakeupPreamble

  test "builds preamble for heartbeat-source run with inbox stats" do
    user = generate(user())
    agent = custom_agent(user, %{heartbeat_default_interval_minutes: 360})

    {:ok, _} =
      Magus.Agents.create_inbox_event(
        %{
          agent_id: agent.id,
          event_type: :content,
          urgency: :deferred,
          title: "Pending event",
          source_type: :integration
        },
        actor: user
      )

    text = WakeupPreamble.build(%{custom_agent: agent, source: :heartbeat, user: user})
    assert text =~ "wake"
    assert text =~ "Inbox"
    assert text =~ "1"
    assert text =~ "list_inbox_events"
    assert text =~ "dismiss_event"
    assert text =~ "set_next_wakeup"
  end

  test "shows empty inbox copy when there are no pending events" do
    user = generate(user())
    agent = custom_agent(user, %{heartbeat_default_interval_minutes: 60})

    text = WakeupPreamble.build(%{custom_agent: agent, source: :heartbeat, user: user})
    assert text =~ "Inbox: empty."
  end

  test "builds preamble for manual_trigger source mentioning the user" do
    user = generate(user())
    agent = custom_agent(user, %{})

    text = WakeupPreamble.build(%{custom_agent: agent, source: :manual_trigger, user: user})
    assert text =~ "manually triggered"
  end

  test "builds preamble for :inbox_urgent with urgent header" do
    user = generate(user())
    agent = custom_agent(user, %{heartbeat_default_interval_minutes: 360})

    text = WakeupPreamble.build(%{custom_agent: agent, source: :inbox_urgent, user: user})
    assert text =~ "urgent inbox event"
    assert text =~ "list_inbox_events"
    assert text =~ "dismiss_event"
    assert text =~ "set_next_wakeup"
  end

  test "returns empty string for non-wakeup sources" do
    user = generate(user())
    agent = custom_agent(user, %{})

    assert WakeupPreamble.build(%{custom_agent: agent, source: :mention, user: user}) == ""

    assert WakeupPreamble.build(%{custom_agent: agent, source: :sub_agent_spawn, user: user}) ==
             ""
  end

  test "returns empty for unknown sources" do
    user = generate(user())
    agent = custom_agent(user, %{})

    assert WakeupPreamble.build(%{custom_agent: agent, source: :other, user: user}) == ""
  end

  test "inbox section lists an immediate event above older deferred events, urgency beats recency" do
    user = generate(user())
    # heartbeat_enabled: false so an :immediate event doesn't trigger
    # TriggerUrgentWake (wake gating is irrelevant to preamble building here).
    agent =
      custom_agent(user, %{heartbeat_default_interval_minutes: 360, heartbeat_enabled: false})

    # Created FIRST (so it's the OLDEST by inserted_at) to prove urgency, not
    # recency, drives the ordering: if the code sorted by recency alone, this
    # would sink to the bottom.
    {:ok, _immediate} =
      Magus.Agents.create_inbox_event(
        %{
          agent_id: agent.id,
          event_type: :content,
          urgency: :immediate,
          title: "Immediate Oldest",
          source_type: :integration
        },
        actor: user
      )

    {:ok, _deferred_1} =
      Magus.Agents.create_inbox_event(
        %{
          agent_id: agent.id,
          event_type: :content,
          urgency: :deferred,
          title: "Deferred Older",
          source_type: :integration
        },
        actor: user
      )

    {:ok, _deferred_2} =
      Magus.Agents.create_inbox_event(
        %{
          agent_id: agent.id,
          event_type: :content,
          urgency: :deferred,
          title: "Deferred Newer",
          source_type: :integration
        },
        actor: user
      )

    text = WakeupPreamble.build(%{custom_agent: agent, source: :heartbeat, user: user})

    immediate_pos = :binary.match(text, "Immediate Oldest") |> elem(0)
    deferred_older_pos = :binary.match(text, "Deferred Older") |> elem(0)
    deferred_newer_pos = :binary.match(text, "Deferred Newer") |> elem(0)

    assert immediate_pos < deferred_older_pos
    assert immediate_pos < deferred_newer_pos
  end

  test "last successful wake-up reflects a completed :inbox_urgent run" do
    user = generate(user())
    agent = custom_agent(user, %{heartbeat_default_interval_minutes: 360})

    {:ok, home} = Magus.Agents.Support.HomeConversation.ensure(user.id, agent.id)

    {:ok, run} =
      Magus.Agents.create_agent_run(
        %{
          kind: :delegate,
          source: :inbox_urgent,
          source_conversation_id: home.id,
          target_agent_id: agent.id,
          target_conversation_id: home.id,
          initiator_user_id: user.id,
          request_id: "urgent-#{Ash.UUID.generate()}",
          objective: "x"
        },
        authorize?: false
      )

    {:ok, started} = Magus.Agents.start_agent_run(run, authorize?: false)
    {:ok, _completed} = Magus.Agents.complete_agent_run(started, authorize?: false)

    text = WakeupPreamble.build(%{custom_agent: agent, source: :heartbeat, user: user})

    refute text =~ "never"
  end
end
