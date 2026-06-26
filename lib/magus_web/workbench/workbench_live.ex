defmodule MagusWeb.Workbench.WorkbenchLive do
  @moduledoc """
  Top-level LiveView for the Workbench shell. Owns the websocket lifecycle
  (mount, handle_params, handle_event, handle_info), holds the high-level
  socket assigns, and renders the layout (mode strip, nav pane, tab bar,
  mobile chrome, tab containers).

  Logic that doesn't belong to the websocket lifecycle is delegated:

    * URL <-> tab/mode translation: `MagusWeb.Workbench.Live.Routing`
    * Tab session mutations:        `MagusWeb.Workbench.Live.TabActions`
    * Cross-workspace navigation:   `MagusWeb.Workbench.Live.WorkspaceNavigation`
    * Detail-view rendering:        `MagusWeb.Workbench.Live.DetailView`
    * PAYG usage assigns:           `MagusWeb.Workbench.Live.Usage`
    * Mobile chrome assigns:        `MagusWeb.Workbench.Mobile.Chrome`
    * Tab label resolution:         `MagusWeb.Workbench.Tab.LabelResolver`
    * Chat URL query params:        `MagusWeb.Workbench.Chat.UrlActions`
    * File-browser URL serializer:  `MagusWeb.Workbench.Resources.FileBrowserView.Url`
  """
  use MagusWeb, :live_view

  alias Magus.Workbench
  alias MagusWeb.Workbench.Chat.PendingMessageHighlight
  alias MagusWeb.Workbench.Layout.{ModeStrip, NavPane, TabBar}
  alias MagusWeb.Workbench.Live.{DetailView, Routing, TabActions, Usage}
  alias MagusWeb.Workbench.Mobile.{Chrome, Drawer, Header, TabsPill}
  alias MagusWeb.Workbench.Resources.FileBrowserView.Url, as: FileBrowserUrl
  alias MagusWeb.Workbench.Signals

  on_mount({MagusWeb.LiveUserAuth, :live_user_required})
  # Note: NotificationSubscription is attached by the router's live_session
  # (see lib/magus_web/router.ex), so it sets `:unread_count` on this socket.

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    # Read from the user record, not the Plug session — select_workspace writes
    # to user.current_workspace_id and push_navigate remounts don't re-seed the
    # Plug session key.
    workspace_id = user.current_workspace_id

    {:ok, raw_tab_session} =
      Workbench.get_or_create_tab_session(user.id, workspace_id, actor: user)

    # Drop any tabs that point at resources outside the current workspace
    # (stale state from URL navigation, resource moves, etc.).
    {:ok, tab_session} =
      Workbench.scope_tabs_to_workspace(raw_tab_session, workspace_id, actor: user)

    workspaces = Magus.Workspaces.my_workspaces!(actor: user)
    current_workspace = Enum.find(workspaces, &(&1.id == workspace_id))

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Magus.PubSub, Signals.workbench_user_topic(user.id))
      Phoenix.PubSub.subscribe(Magus.PubSub, "workbench-tabs:#{user.id}")
      Magus.Endpoint.subscribe("files:files:#{user.id}")
      if workspace_id, do: Magus.Endpoint.subscribe("workspaces:#{workspace_id}:files")

      # User-scoped conversation events (currently only `title_changed`)
      # so the chat nav tree reflects renames driven by the Oban
      # name_conversation trigger or a peer renaming a shared chat.
      Magus.Endpoint.subscribe("chat:conversations:#{user.id}")

      # Per-brain topics so the BrainModeNav reflects page create/rename/
      # move/delete driven by agents (or peers) without a reload. Subscribed
      # for every brain the nav can show, regardless of the active mode, since
      # the workbench process persists across mode switches.
      subscribe_brain_topics(user, workspace_id)
    end

    # `current_chat_conv_id/1` only walks the tabs list — no DB. The DB-backed
    # `most_recent_conv_id_for_user/2` fallback is deferred to start_async so
    # it doesn't block first paint.
    initial_last_conv_id = current_chat_conv_id(tab_session.tabs)

    socket =
      socket
      |> assign(:tab_session, tab_session)
      |> assign(:workspace_id, workspace_id)
      |> assign(:mode, tab_session.mode)
      |> assign(:tabs, tab_session.tabs)
      |> assign(:active_tab_id, tab_session.active_tab_id)
      |> assign(:workspaces, workspaces)
      |> assign(:current_workspace, current_workspace)
      |> assign(:nav_filter, tab_session.nav_filter)
      |> assign(:search_query, "")
      |> assign(:usage_data, nil)
      |> assign(:detail_view, nil)
      |> assign(:agent_edit, nil)
      |> assign(:prompt_edit, nil)
      |> assign(:brain_edit, nil)
      |> assign(:drawer_open?, false)
      |> assign(:tabs_pill_open?, false)
      |> assign(:tabs_enabled, Map.get(user.ui_preferences || %{}, "tabs_enabled", false))
      |> assign(:last_chat_conv_id, initial_last_conv_id)
      |> TabActions.assign_browser_filters()
      |> Chrome.assign_chrome()

    socket =
      if connected?(socket) do
        socket
        |> start_async(:load_usage_data, fn -> Usage.compute(user) end)
        |> maybe_load_last_chat_conv_id(user, workspace_id, initial_last_conv_id)
      else
        socket
      end

    {:ok, socket}
  end

  defp maybe_load_last_chat_conv_id(socket, _user, _workspace_id, conv_id)
       when is_binary(conv_id),
       do: socket

  defp maybe_load_last_chat_conv_id(socket, user, workspace_id, _conv_id) do
    start_async(socket, :load_last_chat_conv_id, fn ->
      most_recent_conv_id_for_user(user, workspace_id)
    end)
  end

  @impl true
  def handle_params(params, uri, socket) do
    maybe_stash_highlight(params)

    socket =
      socket
      |> assign(:current_uri, uri)
      # Clear detail_view by default; detail apply_action clauses re-set it.
      # This ensures navigating from a detail route (e.g. /settings) to a tab
      # route (e.g. /chat/:id) actually exits the detail-view rendering.
      |> assign(:detail_view, nil)
      |> Routing.apply_action(socket.assigns.live_action, params)
      |> Routing.apply_url_mode(params)
      |> TabActions.assign_browser_filters()
      |> Chrome.assign_chrome()
      |> refresh_last_chat_conv_id()

    {:noreply, socket}
  end

  # Stash a `?highlight=<message_id>` deep-link target keyed by conversation id
  # so the freshly-mounted ConversationView can consume it and scroll to the
  # message. Runs in both the dead and connected render phases (handle_params
  # fires in both) to stay balanced with the take at child mount.
  defp maybe_stash_highlight(%{"conversation_id" => conv_id, "highlight" => msg_id})
       when is_binary(conv_id) and is_binary(msg_id) and msg_id != "" do
    PendingMessageHighlight.put(conv_id, msg_id)
  end

  defp maybe_stash_highlight(_), do: :ok

  # Update `:last_chat_conv_id` only when the current tabs still contain a
  # real conversation. For users with tabs disabled, the conversation tab is
  # trimmed when they navigate to a prompt/agent view — keeping the previous
  # value lets PromptView's "Insert into current chat" button still point at
  # the chat the user just came from.
  defp refresh_last_chat_conv_id(socket) do
    case current_chat_conv_id(socket.assigns.tabs) do
      nil -> socket
      id -> assign(socket, :last_chat_conv_id, id)
    end
  end

  # Picks the most recently opened real conversation tab so resource views
  # (e.g. PromptView's "Insert into current chat" button) can target it.
  # Returns the conversation_id or nil if no real conversation tab is open.
  defp current_chat_conv_id(tabs) when is_list(tabs) do
    tabs
    |> Enum.filter(fn tab ->
      primary = tab["primary"] || %{}
      primary["type"] == "conversation" and primary["id"] not in [nil, "new"]
    end)
    |> Enum.sort_by(fn tab -> tab["opened_at"] || "" end, :desc)
    |> List.first()
    |> case do
      nil -> nil
      tab -> tab["primary"]["id"]
    end
  end

  defp current_chat_conv_id(_), do: nil

  # Fallback for `last_chat_conv_id` when no real conversation tab is open
  # (typical for users with `tabs_enabled: false` who land directly on a
  # prompt/agent view). Returns the most recently active conversation in the
  # user's workspace, or `nil` if they have none.
  defp most_recent_conv_id_for_user(_user, nil), do: nil

  defp most_recent_conv_id_for_user(user, workspace_id) do
    require Ash.Query

    case Magus.Chat.workspace_conversations(workspace_id,
           query: [sort: [last_message_at: :desc_nils_last], limit: 1],
           actor: user
         ) do
      {:ok, [conv | _]} -> conv.id
      _ -> nil
    end
  end

  # === handle_event callbacks ==============================================

  @impl true
  def handle_event("select_mode", %{"mode" => mode}, socket) when is_binary(mode) do
    cond do
      mode not in Routing.valid_url_modes() ->
        {:noreply, socket}

      true ->
        atom = String.to_existing_atom(mode)

        if socket.assigns.mode == atom and is_nil(socket.assigns.detail_view) do
          {:noreply, socket}
        else
          socket = Routing.set_mode(socket, atom)

          destination =
            if socket.assigns.detail_view do
              # Exit detail view: navigate to the mode root URL
              Routing.mode_root_path(atom)
            else
              Routing.path_with_mode(socket.assigns.current_uri, atom)
            end

          {:noreply, push_patch(socket, to: destination)}
        end
    end
  end

  def handle_event("select_mode", _params, socket), do: {:noreply, socket}

  def handle_event("select_detail", %{"type" => type, "id" => id}, socket) do
    # ~p does not support dynamic segment interpolation here; using plain string.
    path =
      case type do
        "agent" -> "/agents/#{id}"
        "prompt" -> "/prompts_library/#{id}"
        _ -> "/chat"
      end

    {:noreply,
     socket
     |> assign(:drawer_open?, false)
     |> push_patch(to: path)}
  end

  def handle_event("open_tab", params, socket), do: TabActions.open_tab(socket, params)

  def handle_event("open_thread_in_parent", params, socket),
    do: TabActions.open_thread_in_parent(socket, params)

  def handle_event("new_tab", _params, socket) do
    {:noreply,
     socket
     |> assign(:tabs_pill_open?, false)
     |> push_patch(to: "/chat")}
  end

  def handle_event("activate_tab", params, socket), do: TabActions.activate_tab(socket, params)

  def handle_event("close_tab", params, socket), do: TabActions.close_tab(socket, params)

  def handle_event("set_nav_filter", %{"filter" => filter}, socket) do
    atom = String.to_existing_atom(filter)

    {:ok, updated} =
      Workbench.set_tab_session_nav_filter(socket.assigns.tab_session, atom,
        actor: socket.assigns.current_user
      )

    {:noreply,
     socket
     |> assign(:tab_session, updated)
     |> assign(:nav_filter, atom)}
  end

  def handle_event("new_chat", _params, socket) do
    {:noreply, push_patch(socket, to: "/chat/new")}
  end

  def handle_event("begin_new_folder", _params, socket) do
    send_update(MagusWeb.Workbench.Modes.ChatModeNav,
      id: "chat-mode-nav",
      begin_new_folder: System.unique_integer()
    )

    {:noreply, socket}
  end

  def handle_event("new_agent", _params, socket) do
    {:noreply, push_patch(socket, to: "/agents/new")}
  end

  def handle_event("new_prompt", _params, socket) do
    {:noreply, push_patch(socket, to: "/prompts_library/new")}
  end

  def handle_event("use_prompt", %{"id" => prompt_id}, socket) do
    {:noreply, push_navigate(socket, to: "/chat?use_prompt=#{prompt_id}")}
  end

  def handle_event(
        "use_prompt_in_current",
        %{"id" => prompt_id, "conversation_id" => conv_id},
        socket
      )
      when is_binary(conv_id) and conv_id != "" do
    {:noreply, push_navigate(socket, to: "/chat/#{conv_id}?use_prompt=#{prompt_id}")}
  end

  def handle_event("begin_new_brain", _params, socket) do
    send_update(MagusWeb.Workbench.Modes.BrainModeNav,
      id: "brain-mode-nav",
      begin_new_brain: System.unique_integer()
    )

    {:noreply, socket}
  end

  def handle_event("create_brain_page", params, socket),
    do: TabActions.create_brain_page(socket, params)

  def handle_event("select_workspace", %{"id" => raw_id}, socket) do
    user = socket.assigns.current_user
    workspace_id = if raw_id in [nil, ""], do: nil, else: raw_id

    case Magus.Accounts.select_workspace(user, workspace_id, actor: user) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:drawer_open?, false)
         |> push_navigate(to: "/chat")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not switch workspace")}
    end
  end

  def handle_event("open_create_workspace", _params, socket) do
    {:noreply, push_navigate(socket, to: "/workspaces/new")}
  end

  def handle_event("open_notifications", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("toggle_drawer", _params, socket) do
    {:noreply, assign(socket, :drawer_open?, !socket.assigns.drawer_open?)}
  end

  def handle_event("close_drawer", _params, socket) do
    {:noreply, assign(socket, :drawer_open?, false)}
  end

  def handle_event("toggle_tabs_pill", _params, socket) do
    {:noreply, assign(socket, :tabs_pill_open?, !socket.assigns.tabs_pill_open?)}
  end

  def handle_event("close_overlays", _params, socket) do
    {:noreply,
     socket
     |> assign(:drawer_open?, false)
     |> assign(:tabs_pill_open?, false)}
  end

  def handle_event("close_companion", _params, socket) do
    case Chrome.companion_for_active_tab(socket.assigns) do
      nil ->
        {:noreply, socket}

      _spec ->
        tab_id = socket.assigns.active_tab_id
        Signals.broadcast_close_companion(tab_id)
        {:noreply, socket}
    end
  end

  # === handle_async callbacks ==============================================

  @impl true
  def handle_async(:load_usage_data, {:ok, data}, socket) do
    {:noreply, assign(socket, :usage_data, data)}
  end

  def handle_async(:load_usage_data, {:exit, _reason}, socket) do
    {:noreply, socket}
  end

  def handle_async(:load_last_chat_conv_id, {:ok, conv_id}, socket) do
    # Only adopt the async fallback if the tab list still doesn't have a real
    # conversation tab — tab activity during the load wins.
    case current_chat_conv_id(socket.assigns.tabs) do
      nil -> {:noreply, assign(socket, :last_chat_conv_id, conv_id)}
      _ -> {:noreply, socket}
    end
  end

  def handle_async(:load_last_chat_conv_id, {:exit, _reason}, socket) do
    {:noreply, socket}
  end

  # === handle_info callbacks ===============================================

  @impl true
  def handle_info({:tree_message, {:open_conversation, id, label}}, socket),
    do: TabActions.open_conversation_from_tree(socket, id, label)

  def handle_info({:files_changed, _workspace_id}, socket) do
    send_update(MagusWeb.Workbench.Modes.FilesModeNav, id: "files-mode-nav", reload: true)
    {:noreply, socket}
  end

  def handle_info({:file_browser_patch_from_sidebar, overrides}, socket) do
    case TabActions.find_tab(socket.assigns.tabs, socket.assigns.active_tab_id) do
      %{"primary" => %{"type" => "file_browser"} = primary} ->
        {:noreply,
         push_patch(socket, to: FileBrowserUrl.patch_path_for_overrides(primary, overrides))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:file_browser_patch, %{tab_id: tab_id, overrides: overrides}}, socket) do
    if tab_id == socket.assigns.active_tab_id,
      do: handle_info({:file_browser_patch_from_sidebar, overrides}, socket),
      else: {:noreply, socket}
  end

  # Folder card / sidebar entry-point clicks come in as a navigate request from
  # the sticky child LV (FileBrowserView) or its sidebar nav. Routing through
  # push_patch here keeps the parent shell mounted; otherwise push_navigate
  # from the child would force a full WorkbenchLive remount.
  def handle_info({:file_browser_navigate, %{scope: scope, id: id}}, socket) do
    path =
      case scope do
        "folder" -> "/files/folder/#{id}"
        "knowledge" -> "/files/knowledge/#{id}"
        "my_files" -> "/files"
        scope -> "/files?scope=#{scope}"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  # Breadcrumb clicks inside the file browser's TopBar component need to
  # patch the parent's URL, not the sticky child's. The child broadcasts
  # the precomputed path here.
  def handle_info({:file_browser_navigate_path, path}, socket) when is_binary(path) do
    {:noreply, push_patch(socket, to: path)}
  end

  # Conversation favorites toggled from a sticky `live_render` child
  # (e.g. the chat header's star button) — bridge into the chat-mode-nav
  # tree so the sidebar reflects the change.
  def handle_info({:workbench_user, :conversation_favorites_changed}, socket) do
    send_update(MagusWeb.Workbench.Modes.ChatModeNav.Tree,
      id: "chat-mode-nav-tree",
      reload: System.unique_integer()
    )

    {:noreply, socket}
  end

  # Billable usage was recorded for this user — a chat/image/video response
  # was charged, or out-of-band reconciliation corrected a cost.
  # Recompute the PAYG usage indicator (spent / cap / tokens) so it stays
  # fresh without a reload. Usage is produced in a child conversation LV, so
  # the shell only learns of it through this user-scoped signal.
  def handle_info({:workbench_user, :usage_changed}, socket) do
    user = socket.assigns.current_user
    {:noreply, start_async(socket, :load_usage_data, fn -> Usage.compute(user) end)}
  end

  # A conversation owned by this user was renamed (manual rename or Oban
  # name_conversation trigger). Reload the nav tree so the new title shows
  # without a page reload.
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "chat:conversations:" <> _,
          event: "title_changed"
        },
        socket
      ) do
    send_update(MagusWeb.Workbench.Modes.ChatModeNav.Tree,
      id: "chat-mode-nav-tree",
      reload: System.unique_integer()
    )

    {:noreply, socket}
  end

  # Other broadcasts on the user-scoped conversation topic (create, destroy)
  # currently don't trigger a nav refresh from here — drop them so they
  # don't surface as unexpected messages.
  def handle_info(%Phoenix.Socket.Broadcast{topic: "chat:conversations:" <> _}, socket) do
    {:noreply, socket}
  end

  def handle_info({:ui_preferences_changed, prefs}, socket) when is_map(prefs) do
    {:noreply, assign(socket, :tabs_enabled, Map.get(prefs, "tabs_enabled", false))}
  end

  def handle_info({:replace_new_tab_with_agent, old_tab_id, new_agent_id}, socket) do
    user = socket.assigns.current_user

    label =
      case Magus.Agents.get_custom_agent(new_agent_id, actor: user) do
        {:ok, agent} -> agent.name || "Agent"
        _ -> "Agent"
      end

    TabActions.replace_new_tab_with_resource(
      socket,
      old_tab_id,
      %{"type" => "agent", "id" => new_agent_id},
      label
    )
  end

  def handle_info({:replace_new_tab_with_prompt, old_tab_id, new_prompt_id}, socket) do
    user = socket.assigns.current_user

    label =
      case Magus.Library.get_prompt(new_prompt_id, actor: user) do
        {:ok, prompt} -> prompt.name || "Prompt"
        _ -> "Prompt"
      end

    TabActions.replace_new_tab_with_resource(
      socket,
      old_tab_id,
      %{"type" => "prompt", "id" => new_prompt_id},
      label
    )
  end

  def handle_info({:close_workbench_tab, tab_id}, socket),
    do: TabActions.close_workbench_tab_by_id(socket, tab_id)

  # Brain file blocks: a child LV (BrainPageView, mounted via live_render
  # under TabContainer) cannot itself open a new workbench tab. It
  # broadcasts here on the user-scoped tabs topic; we translate that into
  # the same open_workbench_tab + push_patch flow that explicit nav uses.
  def handle_info({:open_file_in_new_tab, file_id}, socket) do
    user = socket.assigns.current_user

    case Magus.Files.get_file(file_id, actor: user) do
      {:ok, file} ->
        TabActions.open_resource_in_new_tab(
          socket,
          %{"type" => "file", "id" => file.id},
          file.name || "File",
          "Could not open file"
        )

      _ ->
        {:noreply, put_flash(socket, :error, "File no longer available")}
    end
  end

  # Brain page-link click in a child BrainPageView: open the target page
  # in a new workbench tab. Same shape as `:open_file_in_new_tab` above.
  def handle_info({:open_brain_page_in_new_tab, page_id}, socket) do
    user = socket.assigns.current_user

    case Magus.Brain.get_page(page_id, actor: user) do
      {:ok, page} ->
        TabActions.open_resource_in_new_tab(
          socket,
          %{"type" => "brain_page", "id" => page.id},
          page.title || "Page",
          "Could not open page"
        )

      _ ->
        {:noreply, put_flash(socket, :error, "Page no longer available")}
    end
  end

  # Brain page tree events (create / rename / move / delete) broadcast on the
  # per-brain topic. Refresh the BrainModeNav so agent-driven (and peer) page
  # changes appear without a reload. Body-only edits (`page.body_updated`)
  # don't change the tree, so they fall through to the catch-all below.
  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "brain:" <> _, event: event},
        socket
      )
      when event in ["page.created", "page.updated", "page.deleted"] do
    # The BrainModeNav is only mounted while brain mode is active; skip the
    # dispatch otherwise. build_sections is idempotent, so a redundant refresh
    # racing the user's own local edit is harmless.
    if socket.assigns.mode == :brain do
      send_update(MagusWeb.Workbench.Modes.BrainModeNav,
        id: "brain-mode-nav",
        pages_changed: System.unique_integer()
      )
    end

    {:noreply, socket}
  end

  # Forward canonical file PubSub events (from File.pub_sub + BroadcastWorkspaceEvent)
  # to the FilesModeNav LiveComponent so the nav reflects out-of-band create /
  # update / destroy from other tabs, Oban jobs, etc.
  #
  # Note: the user-scoped File pub_sub uses `publish_all`, which emits the
  # action name as the event (e.g. "update_status", "process"), not just the
  # action type. Match by topic only and ignore the event name.
  def handle_info(
        %Phoenix.Socket.Broadcast{topic: topic},
        socket
      ) do
    # The FilesModeNav is only mounted while the files mode is active, so skip
    # the send_update dispatch entirely in any other mode. Background file
    # writes (chunking/embeddings) broadcast on the user-wide topic and would
    # otherwise churn this handler on every workbench process.
    if socket.assigns.mode == :files and
         (file_topic_for_user?(topic, socket.assigns.current_user.id) or
            file_topic_for_workspace?(topic, socket.assigns.workspace_id)) do
      send_update(MagusWeb.Workbench.Modes.FilesModeNav,
        id: "files-mode-nav",
        reload: true
      )
    end

    {:noreply, socket}
  end

  # Topic is already scoped per-user, but a tab can be closed between the
  # TabContainer broadcast and delivery. Tolerate the miss rather than crash.
  def handle_info({:workbench_tab_companion_changed, tab_id, companion_spec}, socket),
    do: TabActions.set_companion(socket, tab_id, companion_spec)

  def handle_info({:forward_agent_edit_state, agent_id, edit?, section}, socket) do
    Phoenix.PubSub.broadcast(
      Magus.PubSub,
      "agent-view:#{agent_id}",
      {:set_edit_state, edit?, section}
    )

    {:noreply, socket}
  end

  def handle_info({:forward_prompt_edit_state, prompt_id, edit?}, socket) do
    Phoenix.PubSub.broadcast(
      Magus.PubSub,
      "prompt-view:#{prompt_id}",
      {:set_edit_state, edit?}
    )

    {:noreply, socket}
  end

  def handle_info({:open_brain_settings, brain_id}, socket) do
    user = socket.assigns.current_user

    case Magus.Brain.get_brain(brain_id, actor: user, load: [:is_shared_to_workspace]) do
      {:ok, brain} -> {:noreply, assign(socket, :brain_edit, brain)}
      _ -> {:noreply, socket}
    end
  end

  # The brain settings modal toggled workspace sharing. Refresh the brain
  # nav so the brain moves between Shared/Personal sections without a page
  # reload, and broadcast on the brain topic so an open BrainPageView can
  # update its header visibility pill.
  def handle_info(
        {MagusWeb.ChatLive.Components.Brain.BrainSettingsModalComponent,
         {:brain_visibility_changed, brain}},
        socket
      ) do
    send_update(MagusWeb.Workbench.Modes.BrainModeNav,
      id: "brain-mode-nav",
      brains_changed: System.unique_integer()
    )

    Magus.Endpoint.broadcast(
      Magus.Brain.Topics.brain(brain.id),
      "brain.visibility_changed",
      %{brain: brain}
    )

    {:noreply, socket}
  end

  def handle_info(
        {MagusWeb.ChatLive.Components.Brain.BrainSettingsModalComponent, {:brain_saved, _brain}},
        socket
      ) do
    send_update(MagusWeb.Workbench.Modes.BrainModeNav,
      id: "brain-mode-nav",
      brains_changed: System.unique_integer()
    )

    {:noreply, assign(socket, :brain_edit, nil)}
  end

  def handle_info(
        {MagusWeb.ChatLive.Components.Brain.BrainSettingsModalComponent,
         {:brain_deleted, _brain_id}},
        socket
      ) do
    send_update(MagusWeb.Workbench.Modes.BrainModeNav,
      id: "brain-mode-nav",
      brains_changed: System.unique_integer()
    )

    {:noreply, assign(socket, :brain_edit, nil)}
  end

  def handle_info(
        {MagusWeb.ChatLive.Components.Brain.BrainSettingsModalComponent, :modal_closed},
        socket
      ) do
    {:noreply, assign(socket, :brain_edit, nil)}
  end

  # Subscribe to the per-brain topic for every brain the nav can show. Mirrors
  # the brain set in BrainModeNav.Data.load_sections: personal brains when not
  # in a workspace, the workspace's brains (shared + personal-in-workspace)
  # otherwise. New brains created after mount are picked up via the existing
  # brain create/delete refresh paths.
  defp subscribe_brain_topics(user, workspace_id) do
    for brain_id <- brain_topic_ids(user, workspace_id) do
      Magus.Endpoint.subscribe(Magus.Brain.Topics.brain(brain_id))
    end
  end

  defp brain_topic_ids(user, nil) do
    Magus.Brain.personal_brains!(actor: user) |> Enum.map(& &1.id)
  rescue
    _ -> []
  end

  defp brain_topic_ids(user, workspace_id) do
    Magus.Brain.list_brains_for_workspace!(workspace_id, actor: user) |> Enum.map(& &1.id)
  rescue
    _ -> []
  end

  defp file_topic_for_user?(topic, user_id), do: topic == "files:files:#{user_id}"

  defp file_topic_for_workspace?(_topic, nil), do: false

  defp file_topic_for_workspace?(topic, workspace_id),
    do: topic == "workspaces:#{workspace_id}:files"

  # === Render ==============================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="workbench-root"
      phx-hook=".DrawerA11y"
      class="workbench fixed inset-0 h-dvh overflow-hidden text-wb-text bg-wb-bg"
      data-mode={@mode}
      data-active-tab-id={@active_tab_id}
      data-drawer-open={to_string(@drawer_open?)}
      data-tabs-pill-open={to_string(@tabs_pill_open?)}
      phx-window-keydown="close_overlays"
      phx-key="Escape"
    >
      <script :type={Phoenix.LiveView.ColocatedHook} name=".DrawerA11y">
        export default {
          mounted() {
            this.lastOpen = this.el.dataset.drawerOpen === "true";
            this.lastFocused = null;
            this.syncFocus();
          },
          updated() {
            this.syncFocus();
          },
          syncFocus() {
            const open = this.el.dataset.drawerOpen === "true";
            if (open === this.lastOpen) return;

            if (open) {
              this.lastFocused = document.activeElement;
              const drawer = this.el.querySelector("[data-mobile-drawer]");
              const focusTarget = drawer?.querySelector(
                "button:not([disabled]), a[href], input:not([disabled]), [tabindex]:not([tabindex='-1'])"
              );
              focusTarget?.focus();
            } else if (this.lastFocused && document.contains(this.lastFocused)) {
              this.lastFocused.focus();
              this.lastFocused = null;
            }

            this.lastOpen = open;
          }
        }
      </script>
      <%!-- Mobile drawer overlay (md:hidden, fixed-positioned internally) --%>
      <div class="md:hidden">
        <Drawer.drawer
          open?={@drawer_open?}
          current_user={@current_user}
          current_mode={@mode}
          current_workspace={@current_workspace}
          workspaces={@workspaces}
          workspace_id={@workspace_id}
          nav_filter={@nav_filter}
          search_query={@search_query}
          current_chat_conv_id={@last_chat_conv_id}
        />
      </div>

      <%!--
        Layout: column on mobile (header above main), row on desktop
        (left rail + main). main_content/1 is rendered exactly once in
        the shared center column to avoid duplicate live_render id errors.
      --%>
      <%!--
        Mobile floating pills overlay the entire workbench so the active
        view uses the full viewport. Stays outside the flex layout below
        so it doesn't reserve a row at the top.
      --%>
      <div class="md:hidden">
        <Header.header variant={@mobile_variant}>
          <:pill :if={@tabs_enabled}>
            <.live_component
              module={TabsPill}
              id="mobile-tabs-pill"
              tabs={@tabs}
              active_tab_id={@active_tab_id}
              open?={@tabs_pill_open?}
            />
          </:pill>
        </Header.header>
      </div>

      <div class="absolute inset-0 flex md:flex-row">
        <%!-- Desktop ModeStrip + NavPane (hidden on mobile) --%>
        <div class="hidden md:flex shrink-0">
          <.live_component
            module={ModeStrip}
            id="mode-strip"
            current_mode={@mode}
            current_user={@current_user}
            unread_count={@unread_count}
            usage_data={@usage_data}
            detail_view_active?={not is_nil(@detail_view)}
          />
          <.live_component
            module={NavPane}
            id="nav-pane"
            current_mode={@mode}
            current_user={@current_user}
            workspace_id={@workspace_id}
            current_workspace={@current_workspace}
            workspaces={@workspaces}
            nav_filter={@nav_filter}
            search_query={@search_query}
            detail_view={@detail_view}
            active_browser_filters={@active_browser_filters}
            current_chat_conv_id={@last_chat_conv_id}
          />
        </div>

        <%!-- Shared center column: TabBar (desktop only) + main --%>
        <div class="flex-1 flex flex-col min-w-0 min-h-0">
          <div :if={@tabs_enabled} class="hidden md:block">
            <.live_component
              module={TabBar}
              id="tab-bar"
              tabs={@tabs}
              active_tab_id={@active_tab_id}
              detail_view={@detail_view}
            />
          </div>
          <main class="flex-1 relative min-h-0 overflow-hidden">
            {main_content(assigns)}
          </main>
        </div>
      </div>

      <.live_component
        module={MagusWeb.ChatLive.Components.Brain.BrainSettingsModalComponent}
        id="brain-settings-modal"
        show={not is_nil(@brain_edit)}
        brain={@brain_edit}
        current_user={@current_user}
      />
    </div>
    """
  end

  defp main_content(assigns) do
    rendered_tabs =
      if assigns.tabs_enabled,
        do: assigns.tabs,
        else: Enum.filter(assigns.tabs, &(&1["id"] == assigns.active_tab_id))

    assigns = assign(assigns, :rendered_tabs, rendered_tabs)

    ~H"""
    <div :if={@detail_view} class="h-full">
      <DetailView.render detail_view={@detail_view} socket={@socket} />
    </div>
    <div :if={is_nil(@detail_view)} class="absolute inset-0">
      <div
        :for={tab <- @rendered_tabs}
        data-tab-id={tab["id"]}
        data-active={to_string(tab["id"] == @active_tab_id)}
        class={[
          "absolute inset-0",
          tab["id"] != @active_tab_id && "hidden"
        ]}
      >
        {live_render(@socket, MagusWeb.Workbench.Tab.TabContainer,
          id: "tab-#{tab["id"]}",
          sticky: true,
          session: %{
            "tab" => tab,
            "workspace_id" => @workspace_id,
            "user_id" => @current_user.id,
            "agent_edit" => @agent_edit,
            "prompt_edit" => @prompt_edit
          }
        )}
      </div>

      <div
        :if={@tabs == []}
        data-empty-state
        class="h-full flex flex-col items-center justify-center gap-4 text-wb-text-muted p-8"
      >
        <.icon name="lucide-message-square" class="w-12 h-12 text-wb-text-dim" />
        <h2 class="wb-subheading">Start a new chat</h2>
        <p class="wb-body max-w-md text-center text-wb-text-muted">
          Pick a conversation or brain from the nav, or start a fresh chat to get going.
        </p>
        <button
          type="button"
          phx-click="new_chat"
          class="px-4 py-2 text-sm rounded-md bg-wb-accent text-white hover:opacity-90 transition-opacity"
        >
          New chat
        </button>
      </div>
    </div>
    """
  end
end
