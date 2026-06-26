defmodule Magus.Agents.Tools.Autonomy.LinkInboxEventTest do
  use Magus.DataCase, async: false
  import Magus.Generators

  alias Magus.Agents.Tools.Autonomy.LinkInboxEvent

  defp create_event(agent, user) do
    {:ok, event} =
      Magus.Agents.create_inbox_event(
        %{
          agent_id: agent.id,
          event_type: :content,
          urgency: :deferred,
          title: "Inbox event",
          source_type: :integration
        },
        actor: user
      )

    event
  end

  defp enqueue_running_run(user, agent, source) do
    home_conversation = generate(conversation(actor: user, is_task_conversation: true))

    attrs = %{
      kind: :delegate,
      source: source,
      source_conversation_id: home_conversation.id,
      target_conversation_id: home_conversation.id,
      target_agent_id: agent.id,
      initiator_user_id: user.id,
      request_id: "rid-#{Ash.UUIDv7.generate()}",
      idempotency_key: "key-#{Ash.UUIDv7.generate()}",
      objective: "wake up",
      metadata: %{}
    }

    {:ok, run} = Magus.Agents.create_agent_run(attrs, authorize?: false)
    {:ok, started} = Magus.Agents.start_agent_run(run, authorize?: false)
    started
  end

  test "links a pending event to the active autonomous run for the agent" do
    user = generate(user())
    agent = custom_agent(user, %{})
    event = create_event(agent, user)
    run = enqueue_running_run(user, agent, :heartbeat)

    {:ok, result} =
      LinkInboxEvent.run(
        %{event_id: event.id},
        %{user_id: user.id, custom_agent_id: agent.id}
      )

    assert result.status == "linked"
    assert result.event_id == event.id
    assert result.run_id == run.id

    reloaded = Ash.get!(Magus.Agents.AgentInboxEvent, event.id, actor: user)
    assert reloaded.agent_run_id == run.id
  end

  test "uses an explicit agent_run_id from context when provided" do
    user = generate(user())
    agent = custom_agent(user, %{})
    event = create_event(agent, user)
    explicit_run = enqueue_running_run(user, agent, :manual_trigger)

    {:ok, result} =
      LinkInboxEvent.run(
        %{event_id: event.id},
        %{
          user_id: user.id,
          custom_agent_id: agent.id,
          agent_run_id: explicit_run.id
        }
      )

    assert result.status == "linked"
    assert result.run_id == explicit_run.id

    reloaded = Ash.get!(Magus.Agents.AgentInboxEvent, event.id, actor: user)
    assert reloaded.agent_run_id == explicit_run.id
  end

  test "rejects when no autonomous run is active for this agent" do
    user = generate(user())
    agent = custom_agent(user, %{})
    event = create_event(agent, user)

    {:ok, %{error: msg}} =
      LinkInboxEvent.run(
        %{event_id: event.id},
        %{user_id: user.id, custom_agent_id: agent.id}
      )

    assert msg =~ "No active autonomous run"
  end

  test "rejects when the event belongs to a different agent" do
    user_a = generate(user())
    user_b = generate(user())
    agent_a = custom_agent(user_a, %{})
    agent_b = custom_agent(user_b, %{})
    event = create_event(agent_b, user_b)
    _run = enqueue_running_run(user_a, agent_a, :heartbeat)

    {:ok, %{error: msg}} =
      LinkInboxEvent.run(
        %{event_id: event.id},
        %{user_id: user_a.id, custom_agent_id: agent_a.id}
      )

    assert msg =~ "does not belong"
  end

  test "rejects when the event id is unknown" do
    user = generate(user())
    agent = custom_agent(user, %{})

    {:ok, %{error: msg}} =
      LinkInboxEvent.run(
        %{event_id: Ash.UUID.generate()},
        %{user_id: user.id, custom_agent_id: agent.id}
      )

    assert msg =~ "Event not found"
  end

  test "rejects when context is missing required fields" do
    {:ok, %{error: msg}} =
      LinkInboxEvent.run(%{event_id: Ash.UUID.generate()}, %{})

    assert msg =~ "Missing"
  end

  test "ignores mention/sub_agent_spawn runs when picking the active run" do
    user = generate(user())
    agent = custom_agent(user, %{})
    event = create_event(agent, user)
    # mention runs should not satisfy the autonomy lookup.
    _mention_run = enqueue_running_run(user, agent, :mention)

    {:ok, %{error: msg}} =
      LinkInboxEvent.run(
        %{event_id: event.id},
        %{user_id: user.id, custom_agent_id: agent.id}
      )

    assert msg =~ "No active autonomous run"
  end
end
