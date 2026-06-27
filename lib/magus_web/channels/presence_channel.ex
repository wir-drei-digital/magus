defmodule MagusWeb.PresenceChannel do
  @moduledoc """
  Per-resource viewer-presence channel (`viewers:<type>:<id>`) for the
  SvelteKit workbench companions (brain page, draft).

  The channel topic deliberately differs from the PubSub presence topic
  (`presence:<type>:<id>`): `Magus.Presence.Tracker` broadcasts `presence_diff`
  on the latter through `Magus.PubSub`, so a channel named `presence:*` would
  receive the raw CRDT diff on its transport fastlane and try to serialize it.
  Like `MagusWeb.BrainChannel`, this channel subscribes to the presence topic
  internally and re-pushes a JSON-safe, deduped viewer list instead.

  Join authorizes through the resource's own Ash read policy (the same actor
  used everywhere else), then `Magus.Presence.track_channel/3` puts this viewer
  on the shared `presence:<type>:<id>` topic — the very topic the workbench
  LiveViews track on — so SPA and LiveView viewers of one page/draft appear in
  a single list. Phoenix.Presence auto-cleans on channel exit; no untrack.

    * `presence.state` — the full deduped viewer list, pushed on join and on
      every change. Each viewer: `%{user_id, name, avatar_path, color,
      visible?}` (the `Magus.Presence.list/2` shape).
  """
  use MagusWeb, :channel

  @impl true
  def join("viewers:" <> rest, _payload, socket) do
    with [type, id] <- String.split(rest, ":", parts: 2),
         {:ok, type_atom} <- supported_type(type),
         {:ok, _resource} <- authorize(type_atom, id, socket.assigns.current_user) do
      send(self(), :after_join)
      {:ok, assign(socket, resource_type: type_atom, resource_id: id)}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  # Whitelist the resource types this channel serves. Restricting here keeps the
  # atoms (`:page`, `:draft`) bounded and the authorizer total.
  defp supported_type("page"), do: {:ok, :page}
  defp supported_type("draft"), do: {:ok, :draft}
  defp supported_type(_), do: :error

  defp authorize(:page, id, user), do: Magus.Brain.get_page(id, actor: user)
  defp authorize(:draft, id, user), do: Magus.Drafts.get_draft(id, actor: user)

  # Track on the shared presence topic and seed the SPA with the current list.
  @impl true
  def handle_info(:after_join, socket) do
    viewers =
      Magus.Presence.track_channel(
        socket.assigns.resource_type,
        socket.assigns.resource_id,
        socket.assigns.current_user
      )

    push(socket, "presence.state", %{viewers: viewers})
    {:noreply, socket}
  end

  # Someone joined/left/toggled visibility: re-list and push the full set.
  # Viewer lists are small, so replacing state is simpler for the SPA than
  # applying CRDT diffs.
  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "presence:" <> _, event: "presence_diff"},
        socket
      ) do
    viewers = Magus.Presence.list(socket.assigns.resource_type, socket.assigns.resource_id)
    push(socket, "presence.state", %{viewers: viewers})
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
