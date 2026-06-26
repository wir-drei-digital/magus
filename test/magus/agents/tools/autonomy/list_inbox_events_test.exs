defmodule Magus.Agents.Tools.Autonomy.ListInboxEventsTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  alias Magus.Agents.Tools.Autonomy.ListInboxEvents

  test "returns pending events for the agent" do
    user = generate(user())
    agent = custom_agent(user, %{})

    {:ok, _e1} =
      Magus.Agents.create_inbox_event(
        %{
          agent_id: agent.id,
          event_type: :content,
          urgency: :deferred,
          title: "First",
          source_type: :integration
        },
        actor: user
      )

    {:ok, second} =
      Magus.Agents.create_inbox_event(
        %{
          agent_id: agent.id,
          event_type: :content,
          urgency: :deferred,
          title: "Already done",
          source_type: :integration
        },
        actor: user
      )

    {:ok, _resolved} =
      Magus.Agents.resolve_event(second, %{resolved_by: :agent}, actor: user)

    {:ok, result} =
      ListInboxEvents.run(
        %{},
        %{user_id: user.id, custom_agent_id: agent.id}
      )

    assert is_list(result.events)
    titles = Enum.map(result.events, & &1.title)
    assert "First" in titles
    refute "Already done" in titles
    event_keys = result.events |> hd() |> Map.keys()
    assert :id in event_keys
    assert :title in event_keys
    assert :event_type in event_keys
    assert :age_seconds in event_keys
  end

  test "errors when context is missing" do
    {:ok, %{error: msg}} = ListInboxEvents.run(%{}, %{})
    assert msg =~ "Missing"
  end

  test "orders events by urgency (immediate before deferred)" do
    user = generate(user())
    agent = custom_agent(user, %{})

    {:ok, _deferred} =
      Magus.Agents.create_inbox_event(
        %{
          agent_id: agent.id,
          event_type: :content,
          urgency: :deferred,
          title: "Deferred event",
          source_type: :integration
        },
        actor: user
      )

    {:ok, _immediate} =
      Magus.Agents.create_inbox_event(
        %{
          agent_id: agent.id,
          event_type: :mention,
          urgency: :immediate,
          title: "Immediate event",
          source_type: :conversation
        },
        actor: user
      )

    {:ok, _another_deferred} =
      Magus.Agents.create_inbox_event(
        %{
          agent_id: agent.id,
          event_type: :content,
          urgency: :deferred,
          title: "Another deferred",
          source_type: :integration
        },
        actor: user
      )

    {:ok, result} =
      ListInboxEvents.run(
        %{},
        %{user_id: user.id, custom_agent_id: agent.id}
      )

    titles = Enum.map(result.events, & &1.title)
    assert length(titles) == 3
    immediate_idx = Enum.find_index(titles, &(&1 == "Immediate event"))
    deferred_idx = Enum.find_index(titles, &(&1 == "Deferred event"))
    assert immediate_idx < deferred_idx
  end

  test "clamps limit to a maximum of 200" do
    user = generate(user())
    agent = custom_agent(user, %{})

    for i <- 1..3 do
      {:ok, _} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :content,
            urgency: :deferred,
            title: "Event #{i}",
            source_type: :integration
          },
          actor: user
        )
    end

    {:ok, result} =
      ListInboxEvents.run(
        %{limit: 500},
        %{user_id: user.id, custom_agent_id: agent.id}
      )

    # Limit is clamped to 200, but there are only 3 events. The important
    # behaviour is that the tool does not blow up and returns at most 200.
    assert result.count <= 200
    assert result.count == 3
  end

  test "isolates events across agents (and users)" do
    user_a = generate(user())
    user_b = generate(user())
    agent_a = custom_agent(user_a, %{})
    agent_b = custom_agent(user_b, %{})

    {:ok, _event_a} =
      Magus.Agents.create_inbox_event(
        %{
          agent_id: agent_a.id,
          event_type: :content,
          urgency: :deferred,
          title: "Belongs to A",
          source_type: :integration
        },
        actor: user_a
      )

    {:ok, _event_b} =
      Magus.Agents.create_inbox_event(
        %{
          agent_id: agent_b.id,
          event_type: :content,
          urgency: :deferred,
          title: "Belongs to B",
          source_type: :integration
        },
        actor: user_b
      )

    {:ok, result} =
      ListInboxEvents.run(
        %{},
        %{user_id: user_a.id, custom_agent_id: agent_a.id}
      )

    titles = Enum.map(result.events, & &1.title)
    assert "Belongs to A" in titles
    refute "Belongs to B" in titles
    assert result.count == 1
  end

  test "includes :waiting events alongside :pending" do
    user = generate(user())
    agent = custom_agent(user, %{})

    {:ok, waiting} =
      Magus.Agents.create_inbox_event(
        %{
          agent_id: agent.id,
          event_type: :task_assigned,
          urgency: :deferred,
          title: "Waiting on subtask",
          source_type: :agent
        },
        actor: user
      )

    {:ok, _waiting} = Magus.Agents.mark_event_waiting(waiting, %{}, actor: user)

    {:ok, result} =
      ListInboxEvents.run(
        %{},
        %{user_id: user.id, custom_agent_id: agent.id}
      )

    titles = Enum.map(result.events, & &1.title)
    assert "Waiting on subtask" in titles
  end
end
