defmodule Magus.Agents.ActivityBroadcaster do
  @moduledoc "Broadcasts agent activity events via PubSub."

  def broadcast_activity(log) do
    payload = %{type: "activity.new", activity: log}

    Phoenix.PubSub.broadcast(Magus.PubSub, "agent_activity:#{log.agent_id}", payload)
    Phoenix.PubSub.broadcast(Magus.PubSub, "agent_activity:user:#{log.user_id}", payload)
  rescue
    _ -> :ok
  end

  def broadcast_inbox_changed(agent_id, user_id) do
    payload = %{type: "activity.inbox_changed", agent_id: agent_id}

    Phoenix.PubSub.broadcast(Magus.PubSub, "agent_activity:#{agent_id}", payload)
    Phoenix.PubSub.broadcast(Magus.PubSub, "agent_activity:user:#{user_id}", payload)
  rescue
    _ -> :ok
  end

  def broadcast_status_changed(agent_id, user_id, status) do
    payload = %{type: "activity.status_changed", agent_id: agent_id, status: status}

    Phoenix.PubSub.broadcast(Magus.PubSub, "agent_activity:#{agent_id}", payload)
    Phoenix.PubSub.broadcast(Magus.PubSub, "agent_activity:user:#{user_id}", payload)
  rescue
    _ -> :ok
  end
end
