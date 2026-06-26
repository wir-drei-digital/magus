defmodule MagusWeb.AgentChannel do
  @moduledoc """
  Per-agent channel (`agent:<custom_agent_id>`) for the SvelteKit workbench
  (migration iteration 6 — agent detail / control room).

  Join authorizes through `Magus.Agents.get_custom_agent/2` with the socket's
  user as actor (same read policies as every other caller), then bridges the
  agent's activity topic:

    * `agent_activity:<agent_id>` (plain `Phoenix.PubSub` maps from
      `Magus.Agents.ActivityBroadcaster`) →
        * `activity.new` — pushed with a JSON-safe summary of the
          `AgentActivityLog` row (the PubSub payload carries the struct)
        * `activity.inbox_changed` / `activity.status_changed` — pushed as
          refetch hints
  """
  use MagusWeb, :channel

  @impl true
  def join("agent:" <> agent_id, _payload, socket) do
    case Magus.Agents.get_custom_agent(agent_id, actor: socket.assigns.current_user) do
      {:ok, agent} ->
        Phoenix.PubSub.subscribe(Magus.PubSub, "agent_activity:#{agent.id}")
        {:ok, assign(socket, :agent_id, agent.id)}

      {:error, _error} ->
        {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info(%{type: "activity.new", activity: log}, socket) do
    push(socket, "activity.new", %{"activity" => serialize_activity(log)})
    {:noreply, socket}
  end

  def handle_info(%{type: "activity.inbox_changed"} = payload, socket) do
    push(socket, "activity.inbox_changed", %{"agent_id" => payload.agent_id})
    {:noreply, socket}
  end

  def handle_info(%{type: "activity.status_changed"} = payload, socket) do
    push(socket, "activity.status_changed", %{
      "agent_id" => payload.agent_id,
      "status" => to_string(payload.status)
    })

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp serialize_activity(log) do
    %{
      "id" => log.id,
      "activity_type" => to_string(log.activity_type),
      "summary" => log.summary,
      "run_id" => log.run_id,
      "conversation_id" => log.conversation_id,
      "model_used" => log.model_used,
      "tokens_used" => log.tokens_used,
      "duration_ms" => log.duration_ms,
      "inserted_at" => log.inserted_at
    }
  end
end
