defmodule Magus.Agents.Tools.Autonomy.DismissEventTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  alias Magus.Agents.Tools.Autonomy.DismissEvent

  test "dismisses a pending event with a reason" do
    user = generate(user())
    agent = custom_agent(user, %{})

    {:ok, event} =
      Magus.Agents.create_inbox_event(
        %{
          agent_id: agent.id,
          event_type: :content,
          urgency: :deferred,
          title: "Noise",
          source_type: :integration
        },
        actor: user
      )

    {:ok, result} =
      DismissEvent.run(
        %{event_id: event.id, reason: "Not relevant"},
        %{user_id: user.id, custom_agent_id: agent.id}
      )

    assert result.status == "dismissed"
    assert result.event_id == event.id

    reloaded = Ash.get!(Magus.Agents.AgentInboxEvent, event.id, actor: user)
    assert reloaded.status == :dismissed
    assert reloaded.resolved_by == :agent
    assert reloaded.resolution_note == "Not relevant"
  end

  test "errors when event is already resolved" do
    user = generate(user())
    agent = custom_agent(user, %{})

    {:ok, event} =
      Magus.Agents.create_inbox_event(
        %{
          agent_id: agent.id,
          event_type: :content,
          urgency: :deferred,
          title: "Done",
          source_type: :integration
        },
        actor: user
      )

    {:ok, _} = Magus.Agents.resolve_event(event, %{resolved_by: :agent}, actor: user)

    {:ok, %{error: _}} =
      DismissEvent.run(
        %{event_id: event.id, reason: "x"},
        %{user_id: user.id, custom_agent_id: agent.id}
      )
  end

  test "errors when event belongs to a different agent" do
    user_a = generate(user())
    user_b = generate(user())
    agent_a = custom_agent(user_a, %{})
    agent_b = custom_agent(user_b, %{})

    {:ok, event} =
      Magus.Agents.create_inbox_event(
        %{
          agent_id: agent_b.id,
          event_type: :content,
          urgency: :deferred,
          title: "Other",
          source_type: :integration
        },
        actor: user_b
      )

    {:ok, %{error: _}} =
      DismissEvent.run(
        %{event_id: event.id, reason: "x"},
        %{user_id: user_a.id, custom_agent_id: agent_a.id}
      )
  end

  test "errors when context is missing" do
    {:ok, %{error: msg}} =
      DismissEvent.run(%{event_id: Ash.UUID.generate(), reason: "x"}, %{})

    assert msg =~ "Missing"
  end
end
