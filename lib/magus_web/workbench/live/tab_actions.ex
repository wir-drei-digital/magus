defmodule MagusWeb.Workbench.Live.TabActions do
  @moduledoc """
  Tab-session mutation primitives plus the bodies of WorkbenchLive callbacks
  that are too non-trivial to keep inline. Two flavors:

  * Primitives (return updated socket) — composed by `Live.Routing` and other
    helpers when handling URL changes.
  * Callback bodies (return `{:noreply, socket}`) — used directly as
    delegates from WorkbenchLive's `handle_event` / `handle_info` clauses.
  """

  use MagusWeb, :verified_routes
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_patch: 2, put_flash: 3, send_update: 2]

  alias Magus.Workbench
  alias MagusWeb.Workbench.Live.Routing
  alias MagusWeb.Workbench.Mobile.Chrome
  alias MagusWeb.Workbench.Signals
  alias MagusWeb.Workbench.Tab.LabelResolver

  # ------------------------------------------------------------------
  # Primitives
  # ------------------------------------------------------------------

  @spec find_tab(tabs :: [map()], id :: String.t() | nil) :: map() | nil
  def find_tab(_tabs, nil), do: nil
  def find_tab(tabs, id), do: Enum.find(tabs, &(&1["id"] == id))

  @spec normalize_label(any()) :: String.t() | nil
  def normalize_label(label) when is_binary(label) and label != "", do: label
  def normalize_label(_), do: nil

  @spec assign_browser_filters(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_browser_filters(socket) do
    assign(socket, :active_browser_filters, active_browser_filters(socket))
  end

  @spec active_browser_filters(Phoenix.LiveView.Socket.t()) :: map()
  def active_browser_filters(socket) do
    case find_tab(socket.assigns.tabs, socket.assigns.active_tab_id) do
      %{"primary" => %{"type" => "file_browser", "filters" => f}} when is_map(f) -> f
      _ -> %{}
    end
  end

  @spec open_and_activate_tab(Phoenix.LiveView.Socket.t(), atom(), map(), map()) ::
          Phoenix.LiveView.Socket.t()
  def open_and_activate_tab(socket, mode, primary, attrs \\ %{}) do
    socket = Routing.set_mode(socket, mode)

    label =
      normalize_label(Map.get(attrs, :label)) ||
        normalize_label(Map.get(attrs, "label")) ||
        LabelResolver.label_for_primary(primary, socket.assigns.current_user)

    {:ok, updated} =
      open_workbench_tab_scoped(socket.assigns.tab_session, primary, %{label: label}, socket)

    socket
    |> assign(:tab_session, updated)
    |> assign(:tabs, updated.tabs)
    |> assign(:active_tab_id, updated.active_tab_id)
    |> assign_browser_filters()
  end

  @spec open_or_update_browser_tab(Phoenix.LiveView.Socket.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def open_or_update_browser_tab(socket, primary) do
    socket = Routing.set_mode(socket, :files)
    user = socket.assigns.current_user

    existing_tab =
      Enum.find(socket.assigns.tab_session.tabs, fn tab ->
        p = tab["primary"] || %{}

        p["type"] == "file_browser" and
          p["scope"] == primary["scope"] and
          p["id"] == primary["id"]
      end)

    case existing_tab do
      nil ->
        label = LabelResolver.label_for_primary(primary, user)

        {:ok, updated} =
          open_workbench_tab_scoped(
            socket.assigns.tab_session,
            primary,
            %{label: label},
            socket
          )

        socket
        |> assign(:tab_session, updated)
        |> assign(:tabs, updated.tabs)
        |> assign(:active_tab_id, updated.active_tab_id)
        |> assign_browser_filters()
        |> broadcast_browser_params(updated.active_tab_id, primary)

      %{"id" => tab_id} ->
        {:ok, updated} =
          Workbench.update_tab_primary(socket.assigns.tab_session, tab_id, primary, actor: user)

        {:ok, updated} = Workbench.activate_workbench_tab(updated, tab_id, actor: user)

        socket
        |> assign(:tab_session, updated)
        |> assign(:tabs, updated.tabs)
        |> assign(:active_tab_id, tab_id)
        |> assign_browser_filters()
        |> broadcast_browser_params(tab_id, primary)
    end
  end

  @spec broadcast_browser_params(Phoenix.LiveView.Socket.t(), String.t(), map()) ::
          Phoenix.LiveView.Socket.t()
  def broadcast_browser_params(socket, tab_id, primary) do
    Phoenix.PubSub.broadcast(
      Magus.PubSub,
      Signals.tab_topic(tab_id),
      {:browser_params_changed,
       %{
         scope: primary["scope"],
         id: primary["id"],
         filters: primary["filters"],
         sort: primary["sort"],
         q: primary["q"]
       }}
    )

    socket
  end

  # Wraps Workbench.open_workbench_tab so that users with tabs disabled don't
  # accumulate hidden tabs in the database. The Ash action handles the trim in
  # the same write via its `:single` argument, avoiding the old open+replace
  # pair of tab-session updates on every resource navigation.
  defp open_workbench_tab_scoped(session, primary, attrs, socket) do
    user = socket.assigns.current_user
    attrs = Map.put(attrs, :single, !socket.assigns.tabs_enabled)

    Workbench.open_workbench_tab(session, primary, attrs, actor: user)
  end

  # ------------------------------------------------------------------
  # handle_event bodies
  # ------------------------------------------------------------------

  @spec open_tab(Phoenix.LiveView.Socket.t(), map()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def open_tab(socket, %{"type" => type, "id" => id} = params) do
    primary = %{"type" => type, "id" => id}
    label = normalize_label(params["label"])

    {:ok, updated} =
      open_workbench_tab_scoped(socket.assigns.tab_session, primary, %{label: label}, socket)

    tab = find_tab(updated.tabs, updated.active_tab_id)

    {:noreply,
     socket
     |> assign(:tab_session, updated)
     |> assign(:tabs, updated.tabs)
     |> assign(:active_tab_id, updated.active_tab_id)
     |> assign(:drawer_open?, false)
     |> assign_browser_filters()
     |> push_patch(to: Routing.tab_to_path(tab))}
  end

  @spec open_thread_in_parent(Phoenix.LiveView.Socket.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def open_thread_in_parent(
        socket,
        %{"parent_id" => parent_id, "thread_id" => thread_id} = params
      ) do
    primary = %{"type" => "conversation", "id" => parent_id}
    label = normalize_label(params["label"])
    user = socket.assigns.current_user
    companion = %{"type" => "thread", "id" => thread_id}

    with {:ok, after_open} <-
           open_workbench_tab_scoped(socket.assigns.tab_session, primary, %{label: label}, socket),
         tab_id = after_open.active_tab_id,
         {:ok, after_companion} <-
           Workbench.set_workbench_companion(after_open, tab_id, companion, actor: user) do
      Signals.broadcast_open_companion(tab_id, companion)
      tab = find_tab(after_companion.tabs, tab_id)

      {:noreply,
       socket
       |> assign(:tab_session, after_companion)
       |> assign(:tabs, after_companion.tabs)
       |> assign(:active_tab_id, tab_id)
       |> assign(:drawer_open?, false)
       |> assign_browser_filters()
       |> push_patch(to: Routing.tab_to_path(tab))}
    else
      _ -> {:noreply, socket}
    end
  end

  @spec activate_tab(Phoenix.LiveView.Socket.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def activate_tab(socket, %{"tab_id" => tab_id}) do
    {:ok, updated} =
      Workbench.activate_workbench_tab(socket.assigns.tab_session, tab_id,
        actor: socket.assigns.current_user
      )

    tab = find_tab(updated.tabs, tab_id)

    {:noreply,
     socket
     |> assign(:tab_session, updated)
     |> assign(:active_tab_id, updated.active_tab_id)
     |> assign(:tabs_pill_open?, false)
     |> assign_browser_filters()
     |> push_patch(to: Routing.tab_to_path(tab))}
  end

  @spec close_tab(Phoenix.LiveView.Socket.t(), map()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def close_tab(socket, %{"tab_id" => tab_id}) do
    {:ok, updated} =
      Workbench.close_workbench_tab(socket.assigns.tab_session, tab_id,
        actor: socket.assigns.current_user
      )

    path =
      case updated.active_tab_id do
        nil ->
          "/chat"

        id ->
          tab = find_tab(updated.tabs, id)
          Routing.tab_to_path(tab)
      end

    pill_open? = if updated.tabs == [], do: false, else: socket.assigns.tabs_pill_open?

    {:noreply,
     socket
     |> assign(:tab_session, updated)
     |> assign(:tabs, updated.tabs)
     |> assign(:active_tab_id, updated.active_tab_id)
     |> assign(:tabs_pill_open?, pill_open?)
     |> assign_browser_filters()
     |> push_patch(to: path)}
  end

  @spec create_brain_page(Phoenix.LiveView.Socket.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def create_brain_page(socket, %{"brain-id" => brain_id}) do
    user = socket.assigns.current_user

    case Magus.Brain.create_page(brain_id, %{}, actor: user) do
      {:ok, page} ->
        primary = %{"type" => "brain_page", "id" => page.id}
        label = page.title || "Untitled"

        {:ok, updated} =
          open_workbench_tab_scoped(
            socket.assigns.tab_session,
            primary,
            %{label: label},
            socket
          )

        tab = find_tab(updated.tabs, updated.active_tab_id)

        send_update(MagusWeb.Workbench.Modes.BrainModeNav,
          id: "brain-mode-nav",
          expand_brain: brain_id
        )

        {:noreply,
         socket
         |> assign(:tab_session, updated)
         |> assign(:tabs, updated.tabs)
         |> assign(:active_tab_id, updated.active_tab_id)
         |> assign_browser_filters()
         |> push_patch(to: Routing.tab_to_path(tab))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not create page")}
    end
  end

  # ------------------------------------------------------------------
  # handle_info bodies
  # ------------------------------------------------------------------

  @spec open_conversation_from_tree(Phoenix.LiveView.Socket.t(), String.t(), String.t() | nil) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def open_conversation_from_tree(socket, id, label) do
    primary = %{"type" => "conversation", "id" => id}

    {:ok, updated} =
      open_workbench_tab_scoped(socket.assigns.tab_session, primary, %{label: label}, socket)

    tab = find_tab(updated.tabs, updated.active_tab_id)

    {:noreply,
     socket
     |> assign(:tab_session, updated)
     |> assign(:tabs, updated.tabs)
     |> assign(:active_tab_id, updated.active_tab_id)
     |> assign_browser_filters()
     |> push_patch(to: Routing.tab_to_path(tab))}
  end

  @doc """
  Replaces a "new"-shaped tab with a real resource tab. Closes the old tab,
  opens a new one with the given primary + label. Used for the
  `:replace_new_tab_with_agent` / `_prompt` info bridges.
  """
  @spec replace_new_tab_with_resource(
          Phoenix.LiveView.Socket.t(),
          String.t(),
          map(),
          String.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def replace_new_tab_with_resource(socket, old_tab_id, primary, label) do
    user = socket.assigns.current_user

    with {:ok, after_close} <-
           Workbench.close_workbench_tab(socket.assigns.tab_session, old_tab_id, actor: user),
         {:ok, after_open} <-
           open_workbench_tab_scoped(after_close, primary, %{label: label}, socket) do
      {:noreply,
       socket
       |> assign(:tab_session, after_open)
       |> assign(:tabs, after_open.tabs)
       |> assign(:active_tab_id, after_open.active_tab_id)
       |> assign_browser_filters()
       |> Chrome.assign_chrome()}
    else
      {:error, _} -> {:noreply, socket}
    end
  end

  @doc """
  Opens a brand-new resource tab from a child LV broadcast (file or brain
  page). Mirrors the explicit-nav open flow but produced from a sticky
  child rather than a user click.
  """
  @spec open_resource_in_new_tab(
          Phoenix.LiveView.Socket.t(),
          map(),
          String.t(),
          error_msg :: String.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def open_resource_in_new_tab(socket, primary, label, error_msg) do
    case open_workbench_tab_scoped(
           socket.assigns.tab_session,
           primary,
           %{label: label},
           socket
         ) do
      {:ok, updated} ->
        tab = find_tab(updated.tabs, updated.active_tab_id)

        {:noreply,
         socket
         |> assign(:tab_session, updated)
         |> assign(:tabs, updated.tabs)
         |> assign(:active_tab_id, updated.active_tab_id)
         |> push_patch(to: Routing.tab_to_path(tab))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, error_msg)}
    end
  end

  @spec close_workbench_tab_by_id(Phoenix.LiveView.Socket.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def close_workbench_tab_by_id(socket, tab_id) do
    user = socket.assigns.current_user

    case Workbench.close_workbench_tab(socket.assigns.tab_session, tab_id, actor: user) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:tab_session, updated)
         |> assign(:tabs, updated.tabs)
         |> assign(:active_tab_id, updated.active_tab_id)
         |> assign_browser_filters()
         |> Chrome.assign_chrome()}

      _ ->
        {:noreply, socket}
    end
  end

  @spec set_companion(Phoenix.LiveView.Socket.t(), String.t(), map() | nil) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def set_companion(socket, tab_id, companion_spec) do
    case Workbench.set_workbench_companion(
           socket.assigns.tab_session,
           tab_id,
           companion_spec,
           actor: socket.assigns.current_user
         ) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:tab_session, updated)
         |> assign(:tabs, updated.tabs)
         |> assign_browser_filters()
         |> Chrome.assign_chrome()}

      {:error, _} ->
        {:noreply, socket}
    end
  end
end
