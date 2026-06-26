defmodule MagusWeb.Workbench.Live.Routing do
  @moduledoc """
  URL <-> tab/mode translation for WorkbenchLive. Owns the dispatch from
  `live_action` atoms to socket transforms (`apply_action`), the URL mode
  parsing (`apply_url_mode`), and the canonical path for any open tab
  (`tab_to_path`).
  """

  use MagusWeb, :verified_routes
  use Gettext, backend: MagusWeb.Gettext
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_navigate: 2, push_patch: 2]

  alias Magus.Workbench
  alias MagusWeb.Workbench.Chat.UrlActions
  alias MagusWeb.Workbench.Detail.Builder
  alias MagusWeb.Workbench.Live.{TabActions, WorkspaceNavigation}
  alias MagusWeb.Workbench.Resources.FileBrowserView.Url, as: FileBrowserUrl

  @valid_url_modes ~w(chat brain files agents prompts)
  @valid_browser_scopes ~w(my_files shared recent templates trash)

  # ------------------------------------------------------------------
  # URL mode parsing
  # ------------------------------------------------------------------

  @doc """
  Returns the list of valid `?mode=` URL values. Callers that need the list
  outside a guard (e.g. an `if` check inside a `handle_event` body) use this;
  guards inside this module use the module attribute directly.
  """
  @spec valid_url_modes() :: [String.t()]
  def valid_url_modes, do: @valid_url_modes

  @spec apply_url_mode(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def apply_url_mode(socket, %{"mode" => mode}) when mode in @valid_url_modes do
    atom = String.to_existing_atom(mode)
    if socket.assigns.mode == atom, do: socket, else: assign(socket, :mode, atom)
  end

  def apply_url_mode(socket, _), do: socket

  @spec path_with_mode(String.t(), atom()) :: String.t()
  def path_with_mode(uri, mode) when is_binary(uri) do
    parsed = URI.parse(uri)

    query =
      (parsed.query || "")
      |> URI.decode_query()
      |> Map.put("mode", to_string(mode))
      |> URI.encode_query()

    (parsed.path || "/chat") <> "?" <> query
  end

  # Returns the canonical root path for a mode. Used when select_mode is fired
  # while a detail view is active — we need to exit the detail view path entirely
  # rather than preserve it with a ?mode= param appended.
  @spec mode_root_path(atom()) :: String.t()
  def mode_root_path(:chat), do: "/chat"
  def mode_root_path(:brain), do: "/brain"
  def mode_root_path(:agents), do: "/agents"
  def mode_root_path(:prompts), do: "/prompts_library"
  def mode_root_path(:files), do: "/files"

  # ------------------------------------------------------------------
  # Set mode (used by TabActions and apply_action clauses)
  # ------------------------------------------------------------------

  @spec set_mode(Phoenix.LiveView.Socket.t(), atom()) :: Phoenix.LiveView.Socket.t()
  def set_mode(socket, mode) do
    if socket.assigns.mode == mode do
      socket
    else
      {:ok, updated} =
        Workbench.set_tab_session_mode(socket.assigns.tab_session, mode,
          actor: socket.assigns.current_user
        )

      socket
      |> assign(:tab_session, updated)
      |> assign(:mode, mode)
    end
  end

  # ------------------------------------------------------------------
  # apply_action: dispatch from live_action atom + params to socket
  # ------------------------------------------------------------------

  @spec apply_action(Phoenix.LiveView.Socket.t(), atom(), map()) :: Phoenix.LiveView.Socket.t()
  def apply_action(socket, :default, params) do
    socket = UrlActions.handle(socket, params)

    cond do
      socket.redirected ->
        socket

      UrlActions.has_action?(params) ->
        # Force a fresh chat tab when URL params encode an action (e.g.
        # `?agent=`, `?use_prompt=`). Resuming the previously active tab
        # would silently drop the pending action stashed by `UrlActions.handle`,
        # since only the new-chat ConversationView mount consumes it.
        open_new_chat_tab(socket)

      true ->
        resume_or_open_chat(socket)
    end
  end

  def apply_action(socket, :conversation, %{"conversation_id" => "new"} = params) do
    # No workspace check: the conversation hasn't been created yet, so it
    # implicitly belongs to whichever workspace the user is currently in.
    # The real workspace gate fires once the conversation has a UUID below.
    socket
    |> UrlActions.handle(params)
    |> open_new_chat_tab()
  end

  def apply_action(socket, :conversation, %{"conversation_id" => id} = params) do
    user = socket.assigns.current_user

    case Magus.Chat.get_conversation(id, actor: user) do
      {:ok, conv} ->
        if conv.workspace_id == socket.assigns.workspace_id do
          socket
          |> TabActions.open_and_activate_tab(
            :chat,
            %{"type" => "conversation", "id" => id},
            %{label: conv.title || "Untitled conversation"}
          )
          |> UrlActions.apply_use_prompt_to_existing_conversation(conv, params)
        else
          WorkspaceNavigation.switch_and_navigate(socket, conv.workspace_id, ~p"/chat/#{id}")
        end

      _ ->
        socket
    end
  end

  def apply_action(socket, :brain_page, %{"page_id" => id}) do
    user = socket.assigns.current_user

    case Magus.Brain.get_page(id, actor: user, load: [:brain]) do
      {:ok, %{brain: %{workspace_id: brain_ws_id}} = page} ->
        if brain_ws_id == socket.assigns.workspace_id do
          TabActions.open_and_activate_tab(
            socket,
            :brain,
            %{"type" => "brain_page", "id" => id},
            %{label: page.title || "Untitled page"}
          )
        else
          # ~p cannot verify routes that use dynamic path segments without sigil support.
          WorkspaceNavigation.switch_and_navigate(socket, brain_ws_id, "/brain/#{id}")
        end

      _ ->
        socket
    end
  end

  def apply_action(socket, :file, %{"id" => id}) do
    user = socket.assigns.current_user

    case Magus.Files.get_file(id, actor: user) do
      {:ok, file} ->
        if file.workspace_id == socket.assigns.workspace_id do
          TabActions.open_and_activate_tab(
            socket,
            :files,
            %{"type" => "file", "id" => id},
            %{label: file.name}
          )
        else
          WorkspaceNavigation.switch_and_navigate(socket, file.workspace_id, "/files/#{id}")
        end

      _ ->
        socket
    end
  end

  def apply_action(socket, :files_browser, params) do
    raw = Map.get(params, "scope", "my_files")
    scope = if raw in @valid_browser_scopes, do: raw, else: "my_files"
    primary = FileBrowserUrl.build_primary(scope, nil, params)
    TabActions.open_or_update_browser_tab(socket, primary)
  end

  def apply_action(socket, :files_browser_folder, %{"id" => id} = params) do
    user = socket.assigns.current_user

    case Magus.Chat.get_folder(id, actor: user) do
      {:ok, folder} ->
        if folder.workspace_id == socket.assigns.workspace_id do
          primary = FileBrowserUrl.build_primary("folder", folder.id, params)
          TabActions.open_or_update_browser_tab(socket, primary)
        else
          WorkspaceNavigation.switch_and_navigate(
            socket,
            folder.workspace_id,
            "/files/folder/#{id}"
          )
        end

      _ ->
        socket
        |> put_flash(:error, gettext("This folder isn't available."))
        |> push_navigate(to: "/files")
    end
  end

  def apply_action(socket, :files_browser_knowledge, %{"id" => id} = params) do
    user = socket.assigns.current_user

    case Magus.Knowledge.get_collection(id, actor: user) do
      {:ok, coll} ->
        if coll.workspace_id == socket.assigns.workspace_id do
          primary = FileBrowserUrl.build_primary("knowledge", coll.id, params)
          TabActions.open_or_update_browser_tab(socket, primary)
        else
          WorkspaceNavigation.switch_and_navigate(
            socket,
            coll.workspace_id,
            "/files/knowledge/#{id}"
          )
        end

      _ ->
        socket
        |> put_flash(:error, gettext("This collection isn't available."))
        |> push_navigate(to: "/files")
    end
  end

  def apply_action(socket, :brain_list, _params), do: set_mode(socket, :brain)
  def apply_action(socket, :agents_list, _params), do: set_mode(socket, :agents)
  def apply_action(socket, :prompts_list, _params), do: set_mode(socket, :prompts)

  def apply_action(socket, :new_agent, _params) do
    socket
    |> assign(:agent_edit, nil)
    |> TabActions.open_and_activate_tab(:agents, %{"type" => "agent", "id" => "new"})
  end

  def apply_action(socket, :agent, %{"agent_id" => "new"}) do
    apply_action(socket, :new_agent, %{})
  end

  def apply_action(socket, :agent, %{"agent_id" => id} = params) do
    user = socket.assigns.current_user
    edit? = Map.get(params, "edit") == "true"
    section = Map.get(params, "section", "general")

    case Magus.Agents.get_custom_agent(id, actor: user) do
      {:ok, agent} ->
        if agent.workspace_id == socket.assigns.workspace_id do
          socket
          |> assign(:agent_edit, if(edit?, do: %{"edit" => "true", "section" => section}))
          |> TabActions.open_and_activate_tab(
            :agents,
            %{"type" => "agent", "id" => id},
            %{label: agent.name}
          )
          |> defer_to_self({:forward_agent_edit_state, id, edit?, section})
        else
          WorkspaceNavigation.switch_and_navigate(socket, agent.workspace_id, "/agents/#{id}")
        end

      _ ->
        socket
    end
  end

  def apply_action(socket, :new_prompt, _params) do
    socket
    |> assign(:prompt_edit, nil)
    |> TabActions.open_and_activate_tab(:prompts, %{"type" => "prompt", "id" => "new"})
  end

  def apply_action(socket, :prompt, %{"prompt_id" => "new"}) do
    apply_action(socket, :new_prompt, %{})
  end

  def apply_action(socket, :prompt, %{"prompt_id" => id} = params) do
    user = socket.assigns.current_user
    edit? = Map.get(params, "edit") == "true"

    case Magus.Library.get_prompt(id, actor: user) do
      {:ok, prompt} ->
        if prompt.workspace_id == socket.assigns.workspace_id do
          socket
          |> assign(:prompt_edit, if(edit?, do: %{"edit" => "true"}))
          |> TabActions.open_and_activate_tab(
            :prompts,
            %{"type" => "prompt", "id" => id},
            %{label: prompt.name}
          )
          |> defer_to_self({:forward_prompt_edit_state, id, edit?})
        else
          WorkspaceNavigation.switch_and_navigate(
            socket,
            prompt.workspace_id,
            "/prompts_library/#{id}"
          )
        end

      _ ->
        socket
    end
  end

  def apply_action(socket, :settings, params) do
    assign(socket, :detail_view, Builder.build_settings(params, socket.assigns.current_user))
  end

  def apply_action(socket, :workspace_settings, %{"slug" => slug}) do
    assign(
      socket,
      :detail_view,
      Builder.build_workspace_settings(slug, socket.assigns.current_user)
    )
  end

  def apply_action(socket, :workspace_members, %{"slug" => slug}) do
    assign(
      socket,
      :detail_view,
      Builder.build_workspace_members(slug, socket.assigns.current_user)
    )
  end

  def apply_action(socket, :workspace_usage, %{"slug" => slug}) do
    assign(
      socket,
      :detail_view,
      Builder.build_workspace_usage(slug, socket.assigns.current_user)
    )
  end

  def apply_action(socket, :jobs, params) do
    assign(socket, :detail_view, Builder.build_jobs(params, socket.assigns.current_user))
  end

  def apply_action(socket, :search, params) do
    assign(socket, :detail_view, Builder.build_search(params, socket.assigns.current_user))
  end

  def apply_action(socket, :history, params) do
    assign(
      socket,
      :detail_view,
      Builder.build_history(params, socket.assigns.current_user, socket.assigns.workspace_id)
    )
  end

  def apply_action(socket, :brain_trash, params) do
    assign(
      socket,
      :detail_view,
      Builder.build_brain_trash(params, socket.assigns.current_user, socket.assigns.workspace_id)
    )
  end

  # Posts a message to the LiveView's own mailbox so the corresponding
  # `handle_info` clause runs after `apply_action` returns. Used by the
  # `:agent` and `:prompt` clauses to broadcast edit-state changes only
  # *after* the freshly-opened tab's `live_render` child has mounted and
  # subscribed to the per-resource PubSub topic — broadcasting inline
  # would race the child's subscription.
  defp defer_to_self(socket, message) do
    send(self(), message)
    socket
  end

  # ------------------------------------------------------------------
  # tab_to_path
  # ------------------------------------------------------------------

  @spec tab_to_path(map() | nil) :: String.t()
  def tab_to_path(%{"primary" => %{"type" => "conversation", "id" => id}}),
    do: ~p"/chat/#{id}"

  # ~p does not support dynamic segment interpolation here; using plain string.
  def tab_to_path(%{"primary" => %{"type" => "brain_page", "id" => id}}),
    do: "/brain/#{id}"

  # ~p does not support dynamic segment interpolation here; using plain string.
  def tab_to_path(%{"primary" => %{"type" => "file", "id" => id}}),
    do: "/files/#{id}"

  # ~p does not support dynamic segment interpolation here; using plain string.
  def tab_to_path(%{"primary" => %{"type" => "agent", "id" => id}}),
    do: "/agents/#{id}"

  # ~p does not support dynamic segment interpolation here; using plain string.
  def tab_to_path(%{"primary" => %{"type" => "prompt", "id" => id}}),
    do: "/prompts_library/#{id}"

  def tab_to_path(%{"primary" => %{"type" => "file_browser"} = primary}) do
    query =
      primary
      |> FileBrowserUrl.url_params()
      |> FileBrowserUrl.drop_nil_or_empty()
      |> URI.encode_query()

    base = FileBrowserUrl.base_path(primary)
    if query == "", do: base, else: FileBrowserUrl.append_query(base, query)
  end

  def tab_to_path(_tab), do: "/chat"

  # ------------------------------------------------------------------
  # Resume helpers (called from :default and :conversation/new clauses)
  # ------------------------------------------------------------------

  # Restore the active tab if any; otherwise open a synthetic "new chat" tab
  # in place. Modeling new chat as a real tab lets it survive mode switches
  # (and gets replaced cleanly when the first message creates the real
  # conversation). If a chat URL action already navigated us elsewhere (e.g.
  # `?skill=`), let the redirect win.
  defp resume_or_open_chat(socket) do
    cond do
      socket.redirected ->
        socket

      tab = active_tab(socket) ->
        push_patch(socket, to: tab_to_path(tab))

      true ->
        open_new_chat_tab(socket)
    end
  end

  defp open_new_chat_tab(socket) do
    if socket.redirected do
      socket
    else
      TabActions.open_and_activate_tab(socket, :chat, %{
        "type" => "conversation",
        "id" => "new"
      })
    end
  end

  defp active_tab(%{assigns: %{tabs_enabled: true, tabs: tabs, active_tab_id: id}}),
    do: TabActions.find_tab(tabs, id)

  defp active_tab(_socket), do: nil
end
