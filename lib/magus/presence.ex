defmodule Magus.Presence do
  @moduledoc """
  Unified presence tracking for collaborative resources.

  Backed by `Phoenix.Presence` (CRDT, cluster-safe). One `Magus.Presence` module
  serves every resource type (conversation, brain page, draft, spreadsheet, ...).
  Topics follow `"presence:\#{resource_type}:\#{resource_id}"`; keys are user UUIDs.
  A user with multiple tabs/processes shows as a single viewer with multiple
  metas; on the last meta leave, the key disappears.

  Public API: `track/3`, `list/2`, `untrack/2`, `handle_diff/2`,
  `handle_visibility/3`. The internal `Phoenix.Presence` module is named
  `Magus.Presence.Tracker` and is only used directly by this module.
  """

  defmodule Tracker do
    use Phoenix.Presence, otp_app: :magus, pubsub_server: Magus.PubSub
  end

  @type resource_type :: :conversation | :page | :draft | :spreadsheet | atom()
  @type resource_id :: String.t()

  @doc false
  def child_spec(opts) do
    # Phoenix.Presence's injected child_spec/1 sets `id: __MODULE__` to the
    # inner tracker module (Magus.Presence.Tracker). Override to keep the
    # supervisor child id consistent with how this module is listed in
    # `application.ex`, while still delegating start to the inner module
    # (which is what registers the Phoenix.Tracker process name).
    inner = __MODULE__.Tracker.child_spec(opts)
    %{inner | id: __MODULE__}
  end

  @doc """
  Tracks the current LiveView process as viewing the given resource and
  subscribes the LV to the presence topic. No-op if the socket is not connected
  or has no `:current_user`.

  Stores the topic in `socket.assigns.__presences__` so `handle_diff/2` can find
  it later, and seeds `socket.assigns.viewers[topic]` with the current viewer
  list (so the first render has data without waiting for the first diff).

  Also initializes `__presences__` and `viewers` assigns (via `assign_new/3`) on
  both connected and disconnected sockets, so templates that read these assigns
  never crash during the disconnected render pass. If the `on_mount Magus.Presence`
  hook is used, the assigns are already set and `assign_new/3` is a no-op.
  """
  @spec track(Phoenix.LiveView.Socket.t(), resource_type(), resource_id()) ::
          Phoenix.LiveView.Socket.t()
  def track(%Phoenix.LiveView.Socket{} = socket, resource_type, resource_id) do
    socket =
      socket
      |> Phoenix.Component.assign_new(:__presences__, fn -> %{} end)
      |> Phoenix.Component.assign_new(:viewers, fn -> %{} end)

    with true <- Phoenix.LiveView.connected?(socket),
         user when not is_nil(user) <- socket.assigns[:current_user] do
      topic = topic(resource_type, resource_id)
      meta = build_meta(user)

      Phoenix.PubSub.subscribe(Magus.PubSub, topic)
      {:ok, _ref} = __MODULE__.Tracker.track(self(), topic, user.id, meta)

      new_presences = Map.put(socket.assigns.__presences__ || %{}, topic, :tracked)

      new_viewers =
        Map.put(socket.assigns.viewers || %{}, topic, list(resource_type, resource_id))

      socket
      |> Phoenix.Component.assign(:__presences__, new_presences)
      |> Phoenix.Component.assign(:viewers, new_viewers)
    else
      _ -> socket
    end
  end

  @doc """
  Channel/GenServer variant of `track/3`: tracks the **calling process** as
  viewing the resource on the same presence topic the workbench LiveViews use,
  subscribes it to that topic, and returns the current viewer list.

  Use from a `Phoenix.Channel` (which carries a `Phoenix.Socket`, not a
  `LiveView.Socket`) so SPA and LiveView viewers of one resource appear in a
  single presence list. `Phoenix.Presence` auto-cleans on process exit, so the
  caller needs no explicit `untrack`.
  """
  @spec track_channel(resource_type(), resource_id(), map()) :: [map()]
  def track_channel(resource_type, resource_id, user) do
    topic = topic(resource_type, resource_id)
    Phoenix.PubSub.subscribe(Magus.PubSub, topic)
    {:ok, _ref} = __MODULE__.Tracker.track(self(), topic, user.id, build_meta(user))
    list(resource_type, resource_id)
  end

  @doc """
  Returns the deduped list of viewers for `{resource_type, resource_id}`.

  Each entry: `%{user_id, name, avatar_path, color, visible?}`. Hidden viewers
  (visible? == false) are included; the indicator component filters them out
  for rendering.
  """
  @spec list(resource_type(), resource_id()) :: [map()]
  def list(resource_type, resource_id) do
    resource_type
    |> topic(resource_id)
    |> __MODULE__.Tracker.list()
    |> Enum.map(fn {user_id, %{metas: metas}} ->
      # Use the most recently joined meta (last in list) for display values.
      meta = List.last(metas)

      %{
        user_id: user_id,
        name: meta[:name],
        avatar_path: meta[:avatar_path],
        color: meta[:color],
        visible?: Enum.any?(metas, &Map.get(&1, :visible?, true))
      }
    end)
  end

  @doc """
  Untracks the current process from a tracked resource and unsubscribes the LV
  from the topic. Typically not needed — the LV process death auto-cleans
  Presence — but useful if a single LV switches between resources at runtime
  (e.g., conversation switcher in workbench chat).
  """
  @spec untrack(Phoenix.LiveView.Socket.t(), resource_type(), resource_id()) ::
          Phoenix.LiveView.Socket.t()
  def untrack(%Phoenix.LiveView.Socket{} = socket, resource_type, resource_id) do
    with true <- Phoenix.LiveView.connected?(socket),
         user when not is_nil(user) <- socket.assigns[:current_user] do
      topic = topic(resource_type, resource_id)
      :ok = __MODULE__.Tracker.untrack(self(), topic, user.id)
      Phoenix.PubSub.unsubscribe(Magus.PubSub, topic)

      new_presences = Map.delete(socket.assigns.__presences__ || %{}, topic)
      new_viewers = Map.delete(socket.assigns.viewers || %{}, topic)

      socket
      |> Phoenix.Component.assign(:__presences__, new_presences)
      |> Phoenix.Component.assign(:viewers, new_viewers)
    else
      _ -> socket
    end
  end

  @doc """
  LiveView helper: refreshes the viewers list for the topic carried in the
  broadcast. Returns the socket unchanged if the topic isn't tracked by this LV.

  Use in `handle_info/2`:

      def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"} = msg, socket),
        do: {:noreply, Magus.Presence.handle_diff(socket, msg)}
  """
  @spec handle_diff(Phoenix.LiveView.Socket.t(), Phoenix.Socket.Broadcast.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_diff(socket, %Phoenix.Socket.Broadcast{topic: topic, event: "presence_diff"}) do
    presences = socket.assigns[:__presences__] || %{}

    if Map.has_key?(presences, topic) do
      {resource_type, resource_id} = parse_topic(topic)
      viewers = list(resource_type, resource_id)

      Phoenix.Component.assign(
        socket,
        :viewers,
        Map.put(socket.assigns.viewers || %{}, topic, viewers)
      )
    else
      socket
    end
  end

  @doc """
  LiveView helper for visibility events from the colocated hook. Updates the
  meta's `visible?` flag without untracking — avoids `presence_diff` storms on
  every alt-tab. Other clients re-render via the next `presence_diff` (Phoenix
  broadcasts on updates too).

  `event` is `"presence:visible"` or `"presence:hidden"`.
  """
  @spec handle_visibility(Phoenix.LiveView.Socket.t(), String.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def handle_visibility(socket, event, %{"topic" => topic}) do
    presences = socket.assigns[:__presences__] || %{}

    cond do
      not Map.has_key?(presences, topic) ->
        socket

      socket.assigns[:current_user] == nil ->
        socket

      true ->
        visible? = event == "presence:visible"
        user_id = socket.assigns.current_user.id

        __MODULE__.Tracker.update(self(), topic, user_id, fn meta ->
          Map.put(meta, :visible?, visible?)
        end)

        socket
    end
  end

  @doc """
  LiveView `on_mount` hook that seeds presence assigns and attaches the
  `presence_diff` info handler plus the `presence:visible`/`presence:hidden`
  event handler.

  Use in any LiveView that calls `Magus.Presence.track/3`:

      on_mount Magus.Presence

  The hook initializes `socket.assigns.__presences__` and `socket.assigns.viewers`
  to `%{}` so the template can safely read them in the disconnected render pass,
  and attaches:

    * `handle_info` for `%Phoenix.Socket.Broadcast{event: "presence_diff"}`
    * `handle_event` for `"presence:visible"` / `"presence:hidden"`

  Both delegate to `handle_diff/2` / `handle_visibility/3`.
  """
  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> Phoenix.Component.assign(:__presences__, %{})
      |> Phoenix.Component.assign(:viewers, %{})
      |> Phoenix.LiveView.attach_hook(:presence_diff, :handle_info, &handle_diff_hook/2)
      |> Phoenix.LiveView.attach_hook(
        :presence_visibility,
        :handle_event,
        &handle_visibility_hook/3
      )

    {:cont, socket}
  end

  defp handle_diff_hook(%Phoenix.Socket.Broadcast{event: "presence_diff"} = msg, socket) do
    {:halt, handle_diff(socket, msg)}
  end

  defp handle_diff_hook(_msg, socket), do: {:cont, socket}

  defp handle_visibility_hook("presence:" <> _rest = event, params, socket) do
    {:halt, handle_visibility(socket, event, params)}
  end

  defp handle_visibility_hook(_event, _params, socket), do: {:cont, socket}

  defp parse_topic("presence:" <> rest) do
    [type, id] = String.split(rest, ":", parts: 2)
    {String.to_existing_atom(type), id}
  end

  defp topic(resource_type, resource_id)
       when is_atom(resource_type) and is_binary(resource_id) do
    "presence:#{resource_type}:#{resource_id}"
  end

  defp build_meta(user) do
    %{
      name: user.name || user.email,
      avatar_path: Map.get(user, :avatar_path),
      color: color_for_user(user.id),
      joined_at: DateTime.utc_now(),
      visible?: true
    }
  end

  # Deterministic color from user UUID. 8 hand-picked saturated colors that work
  # on both light and dark backgrounds.
  @colors ~w(#ef4444 #f59e0b #10b981 #3b82f6 #8b5cf6 #ec4899 #14b8a6 #f97316)
  defp color_for_user(user_id) when is_binary(user_id) do
    Enum.at(@colors, :erlang.phash2(user_id, length(@colors)))
  end
end
