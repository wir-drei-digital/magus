defmodule MagusWeb.BrainChannel do
  @moduledoc """
  Per-brain channel (`brain_updates:<brain_id>`) for the SvelteKit workbench
  (migration iteration 7 — brain mode nav + page editor).

  The channel topic deliberately differs from the PubSub topic: the classic
  `Magus.Brain.Topics.brain/1` topic (`brain:<id>`) is broadcast through
  `MagusWeb.Endpoint` with struct payloads, so a channel named `brain:*`
  would receive those broadcasts on its transport fastlane and crash the
  JSON serializer. This channel subscribes to that topic internally and
  re-pushes JSON-safe summaries:

    * `page.created` / `page.updated` / `page.deleted` → tree refetch hints
      (`page_id`, `actor_id`)
    * `page.body_updated` → adds `lock_version` + `source` so an open editor
      can detect concurrent saves without refetching blindly
  """
  use MagusWeb, :channel

  @impl true
  def join("brain_updates:" <> brain_id, _payload, socket) do
    case Magus.Brain.get_brain(brain_id, actor: socket.assigns.current_user) do
      {:ok, brain} ->
        Magus.Endpoint.subscribe(Magus.Brain.Topics.brain(brain.id))
        {:ok, assign(socket, :brain_id, brain.id)}

      {:error, _error} ->
        {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "brain:" <> _, event: event, payload: payload},
        socket
      ) do
    push(socket, event, serialize(event, payload))
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp serialize("page.body_updated", payload) do
    %{
      "page_id" => payload.record.id,
      "lock_version" => payload.lock_version,
      "actor_id" => payload[:actor_id],
      "source" => to_string(payload[:source] || :user)
    }
  end

  defp serialize(_event, %{record: record} = payload) do
    %{"page_id" => record.id, "actor_id" => payload[:actor_id]}
  end

  defp serialize(_event, _payload), do: %{}
end
