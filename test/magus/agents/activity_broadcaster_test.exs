defmodule Magus.Agents.ActivityBroadcasterTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Agents.ActivityBroadcaster

  setup do
    user = generate(user())
    agent = custom_agent(user)

    %{user: user, agent: agent}
  end

  describe "broadcast_activity/1 via AgentActivityLog create" do
    test "broadcasts activity.new to per-agent topic when log is created", %{
      user: user,
      agent: agent
    } do
      Phoenix.PubSub.subscribe(Magus.PubSub, "agent_activity:#{agent.id}")

      {:ok, log} =
        Magus.Agents.create_activity_log(
          %{
            agent_id: agent.id,
            activity_type: :triage_completed,
            summary: "Triage done"
          },
          actor: user
        )

      assert_receive %{type: "activity.new", activity: received_log}, 1000
      assert received_log.id == log.id
    end

    test "broadcasts activity.new to per-user topic when log is created", %{
      user: user,
      agent: agent
    } do
      Phoenix.PubSub.subscribe(Magus.PubSub, "agent_activity:user:#{user.id}")

      {:ok, log} =
        Magus.Agents.create_activity_log(
          %{
            agent_id: agent.id,
            activity_type: :response_sent,
            summary: "Reply sent"
          },
          actor: user
        )

      assert_receive %{type: "activity.new", activity: received_log}, 1000
      assert received_log.id == log.id
    end
  end

  describe "broadcast_inbox_changed/2 via AgentInboxEvent actions" do
    test "broadcasts activity.inbox_changed to per-agent topic on create", %{
      user: user,
      agent: agent
    } do
      Phoenix.PubSub.subscribe(Magus.PubSub, "agent_activity:#{agent.id}")

      {:ok, _event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :mention,
            title: "You were mentioned",
            source_type: :conversation
          },
          actor: user
        )

      assert_receive %{type: "activity.inbox_changed", agent_id: received_agent_id}, 1000
      assert received_agent_id == agent.id
    end

    test "broadcasts activity.inbox_changed to per-user topic on create", %{
      user: user,
      agent: agent
    } do
      Phoenix.PubSub.subscribe(Magus.PubSub, "agent_activity:user:#{user.id}")

      {:ok, _event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :mention,
            title: "You were mentioned",
            source_type: :conversation
          },
          actor: user
        )

      assert_receive %{type: "activity.inbox_changed", agent_id: received_agent_id}, 1000
      assert received_agent_id == agent.id
    end

    test "broadcasts activity.inbox_changed on resolve", %{user: user, agent: agent} do
      Phoenix.PubSub.subscribe(Magus.PubSub, "agent_activity:#{agent.id}")

      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :task_assigned,
            title: "Task",
            source_type: :agent
          },
          actor: user
        )

      # consume the create broadcast
      assert_receive %{type: "activity.inbox_changed"}, 1000

      {:ok, _resolved} =
        Magus.Agents.resolve_event(event, %{resolved_by: :agent}, actor: user)

      assert_receive %{type: "activity.inbox_changed", agent_id: received_agent_id}, 1000
      assert received_agent_id == agent.id
    end

    test "broadcasts activity.inbox_changed on dismiss", %{user: user, agent: agent} do
      Phoenix.PubSub.subscribe(Magus.PubSub, "agent_activity:#{agent.id}")

      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :content,
            title: "Old news",
            source_type: :integration
          },
          actor: user
        )

      assert_receive %{type: "activity.inbox_changed"}, 1000

      {:ok, _dismissed} =
        Magus.Agents.dismiss_event(event, %{resolution_note: "Not relevant"}, actor: user)

      assert_receive %{type: "activity.inbox_changed", agent_id: received_agent_id}, 1000
      assert received_agent_id == agent.id
    end

    test "broadcasts activity.inbox_changed on mark_waiting", %{user: user, agent: agent} do
      Phoenix.PubSub.subscribe(Magus.PubSub, "agent_activity:#{agent.id}")

      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :task_assigned,
            title: "Blocked task",
            source_type: :agent
          },
          actor: user
        )

      assert_receive %{type: "activity.inbox_changed"}, 1000

      {:ok, _waiting} = Magus.Agents.mark_event_waiting(event, %{}, actor: user)

      assert_receive %{type: "activity.inbox_changed", agent_id: received_agent_id}, 1000
      assert received_agent_id == agent.id
    end

    test "broadcasts activity.inbox_changed on expire", %{user: user, agent: agent} do
      Phoenix.PubSub.subscribe(Magus.PubSub, "agent_activity:#{agent.id}")

      {:ok, event} =
        Magus.Agents.create_inbox_event(
          %{
            agent_id: agent.id,
            event_type: :system,
            title: "Expiring",
            source_type: :system,
            expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
          },
          actor: user
        )

      assert_receive %{type: "activity.inbox_changed"}, 1000

      {:ok, _expired} = Magus.Agents.expire_event(event, actor: user)

      assert_receive %{type: "activity.inbox_changed", agent_id: received_agent_id}, 1000
      assert received_agent_id == agent.id
    end
  end

  describe "broadcast_activity/1 direct call" do
    test "broadcasts to both topics", %{user: user, agent: agent} do
      Phoenix.PubSub.subscribe(Magus.PubSub, "agent_activity:#{agent.id}")
      Phoenix.PubSub.subscribe(Magus.PubSub, "agent_activity:user:#{user.id}")

      fake_log = %{agent_id: agent.id, user_id: user.id, id: Ash.UUIDv7.generate()}
      ActivityBroadcaster.broadcast_activity(fake_log)

      assert_receive %{type: "activity.new", activity: ^fake_log}, 1000
      assert_receive %{type: "activity.new", activity: ^fake_log}, 1000
    end
  end

  describe "broadcast_inbox_changed/2 direct call" do
    test "broadcasts to both topics", %{user: user, agent: agent} do
      Phoenix.PubSub.subscribe(Magus.PubSub, "agent_activity:#{agent.id}")
      Phoenix.PubSub.subscribe(Magus.PubSub, "agent_activity:user:#{user.id}")

      ActivityBroadcaster.broadcast_inbox_changed(agent.id, user.id)

      assert_receive %{type: "activity.inbox_changed", agent_id: aid}, 1000
      assert aid == agent.id
      assert_receive %{type: "activity.inbox_changed", agent_id: aid2}, 1000
      assert aid2 == agent.id
    end
  end

  describe "broadcast_status_changed/3 direct call" do
    test "broadcasts to both topics", %{user: user, agent: agent} do
      Phoenix.PubSub.subscribe(Magus.PubSub, "agent_activity:#{agent.id}")
      Phoenix.PubSub.subscribe(Magus.PubSub, "agent_activity:user:#{user.id}")

      ActivityBroadcaster.broadcast_status_changed(agent.id, user.id, :running)

      assert_receive %{type: "activity.status_changed", agent_id: aid, status: :running}, 1000
      assert aid == agent.id
      assert_receive %{type: "activity.status_changed", agent_id: aid2, status: :running}, 1000
      assert aid2 == agent.id
    end
  end
end
