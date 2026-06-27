defmodule MagusWeb.ConversationPresenceChannel do
  @moduledoc """
  Per-user aggregate presence feed for the SvelteKit chat nav
  (`conversation_presence:<user_id>`).

  The chat nav shows, on each collaborative conversation row, who else is
  currently viewing it. Joining one channel per visible conversation would be
  wasteful, so the nav joins this single feed and pushes the set of
  conversation ids it currently displays via a `watch` event. The server
  authorizes each id through the conversation read policy (so it never reveals
  viewers of a conversation the user cannot access), subscribes to that
  conversation's shared `presence:conversation:<id>` topic — the same topic the
  workbench LiveViews and `MagusWeb.ConversationChannel` track on — and pushes
  viewer lists back:

    * `presence.snapshot` — full `%{conversation_id => viewers}` after a watch
    * `presence.update` — one `%{conversation_id, viewers}` per diff

  Viewer maps are the deduped `Magus.Presence.list/2` shape; self is included
  and the SPA filters it out. Phoenix.Presence auto-cleans on channel exit.
  """
  use MagusWeb, :channel

  require Logger

  # Cap how many conversations one nav can watch. Far above any realistic
  # collaborative set; a runaway client gets logged, not unbounded fan-out.
  @max_watched 100

  @impl true
  def join("conversation_presence:" <> user_id, _payload, socket) do
    if user_id == socket.assigns.user_id do
      {:ok, assign(socket, :watched, MapSet.new())}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("watch", %{"conversation_ids" => ids}, socket) when is_list(ids) do
    user = socket.assigns.current_user

    requested =
      ids
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> cap_watched()

    # Authorize: keep only conversations the actor may actually read. Don't
    # leak who is viewing a conversation the requester can't see.
    authorized =
      requested
      |> Enum.filter(fn id -> match?({:ok, _}, Magus.Chat.get_conversation(id, actor: user)) end)
      |> MapSet.new()

    current = socket.assigns.watched

    for id <- MapSet.difference(authorized, current),
        do: Phoenix.PubSub.subscribe(Magus.PubSub, presence_topic(id))

    for id <- MapSet.difference(current, authorized),
        do: Phoenix.PubSub.unsubscribe(Magus.PubSub, presence_topic(id))

    snapshot =
      Map.new(authorized, fn id -> {id, Magus.Presence.list(:conversation, id)} end)

    push(socket, "presence.snapshot", %{conversations: snapshot})
    {:noreply, assign(socket, :watched, authorized)}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  # A diff on a watched conversation's shared topic: re-list just that one and
  # push an incremental update so the nav row updates without a full snapshot.
  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "presence:conversation:" <> conversation_id,
          event: "presence_diff"
        },
        socket
      ) do
    if MapSet.member?(socket.assigns.watched, conversation_id) do
      viewers = Magus.Presence.list(:conversation, conversation_id)
      push(socket, "presence.update", %{conversation_id: conversation_id, viewers: viewers})
    end

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp presence_topic(conversation_id), do: "presence:conversation:#{conversation_id}"

  defp cap_watched(ids) when length(ids) <= @max_watched, do: ids

  defp cap_watched(ids) do
    Logger.warning(
      "ConversationPresenceChannel watch list of #{length(ids)} exceeds cap #{@max_watched}; truncating"
    )

    Enum.take(ids, @max_watched)
  end
end
