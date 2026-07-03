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
end
