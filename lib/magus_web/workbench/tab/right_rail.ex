defmodule MagusWeb.Workbench.Tab.RightRail do
  @moduledoc """
  Header-mounted "Panels" popover. Replaces the legacy right-edge icon rail.
  Mounted by `ConversationView` inside the chat header (existing tabs only,
  not on the new chat page).

  Renders a single `wb-pill-btn` trigger in the header. Clicking opens a
  fixed-height popover anchored under the trigger, containing:
    * a vertical mini-rail of icons on the left (Prompts/Brains/Drafts/...)
    * the active panel's body on the right (LibrarySidebarComponent / JobsPanel)

  Per-conversation data (folder_id, active system prompt, draft list) is
  lazy-loaded on first panel open and cached in the component state to avoid
  re-fetching on every parent re-render.
  """
  use MagusWeb, :live_component

  alias MagusWeb.ChatLive.Components.Library.LibrarySidebarComponent

  @items [
    {:prompts, "lucide-scroll-text", "Prompts", :always},
    {:brains, "lucide-brain", "Brains", :always},
    {:drafts, "lucide-file-text", "Drafts", :conversation},
    {:files, "lucide-files", "Files", :always},
    {:settings, "lucide-settings", "Settings", :always},
    {:jobs, "lucide-clock", "Jobs", :has_jobs}
  ]

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:open_panel, nil)
     |> assign(:panel_data_loaded?, false)
     |> assign(:has_jobs_loaded_for, :unset)
     |> assign(:has_jobs, false)
     |> assign(:current_user, nil)
     |> assign(:folder_id, nil)
     |> assign(:active_system_prompt, nil)
     |> assign(:conversation_drafts, [])
     |> assign(:active_draft_id, nil)
     |> assign(:active_page_id, nil)}
  end

  @impl true
  def update(%{panel_data_dirty?: true}, socket) do
    # Sent via send_update from TabContainer when a panel-relevant domain
    # change happens (prompt activated, draft deleted, etc.). Invalidates
    # the cached per-conversation panel data and the has_jobs flag.
    socket =
      socket
      |> assign(:panel_data_loaded?, false)
      |> assign(:has_jobs_loaded_for, :unset)

    # If a panel is currently open the user expects the change to land
    # immediately — refetch now rather than waiting for the next toggle.
    socket =
      if socket.assigns.open_panel, do: ensure_panel_data(socket), else: socket

    {:ok, socket}
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if socket.assigns.has_jobs_loaded_for != socket.assigns.conversation_id do
        socket
        |> assign(:has_jobs, has_active_jobs?(socket.assigns))
        |> assign(:has_jobs_loaded_for, socket.assigns.conversation_id)
      else
        socket
      end

    {:ok, socket}
  end

  defp has_active_jobs?(%{conversation_id: nil}), do: false

  defp has_active_jobs?(%{conversation_id: id, user_id: user_id}) do
    user = Magus.Accounts.get_user!(user_id, authorize?: false)

    case Magus.Workflows.list_jobs_for_conversation(id, actor: user) do
      {:ok, jobs} -> jobs != []
      _ -> false
    end
  end

  defp has_active_jobs?(_), do: false

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :items, @items)

    ~H"""
    <div
      class="relative hidden md:block"
      phx-click-away={@open_panel && "close_panel"}
      phx-window-keydown="close_panel"
      phx-key="Escape"
      phx-target={@myself}
    >
      <button
        type="button"
        data-right-rail-trigger
        phx-click="toggle_panel"
        phx-value-panel={@open_panel || :prompts}
        phx-target={@myself}
        class={["wb-pill-btn", @open_panel && "wb-pill-btn-active"]}
        title={if @open_panel, do: "Close panels", else: "Open panels"}
        aria-haspopup="true"
        aria-expanded={if @open_panel, do: "true", else: "false"}
      >
        <.icon name="lucide-more-horizontal" class="w-4 h-4" />
        <span>{gettext("More")}</span>
      </button>

      <div
        :if={@open_panel}
        data-right-rail-panel={@open_panel}
        id={"rail-panel-#{@open_panel}"}
        class="absolute right-0 top-full mt-1 w-[28rem] h-[28rem] flex bg-wb-surface border border-wb-border rounded-lg shadow-lg z-30 overflow-hidden"
      >
        <div class="w-12 shrink-0 border-r border-wb-border flex flex-col items-center py-2 gap-1 bg-wb-bg/40">
          <%= for {key, icon, title, visibility} <- @items, visible?(visibility, assigns) do %>
            <button
              type="button"
              data-rail-icon={key}
              phx-click="select_panel"
              phx-value-panel={key}
              phx-target={@myself}
              title={title}
              class={[
                "w-7 h-7 rounded-full flex items-center justify-center transition-colors",
                @open_panel == key && "bg-wb-surface-2 text-wb-text",
                @open_panel != key && "text-wb-text-muted hover:bg-wb-hover hover:text-wb-text"
              ]}
            >
              <.icon name={icon} class="w-4 h-4" />
            </button>
          <% end %>
        </div>
        <div class="flex-1 min-w-0 overflow-hidden">
          {render_panel_body(assigns)}
        </div>
      </div>
    </div>
    """
  end

  defp render_panel_body(%{open_panel: :jobs} = assigns) do
    ~H"""
    <.live_component
      module={MagusWeb.Workbench.Tab.RightRail.JobsPanel}
      id="rail-jobs"
      user_id={@user_id}
      conversation_id={@conversation_id}
    />
    """
  end

  defp render_panel_body(%{open_panel: panel} = assigns)
       when panel in [:prompts, :brains, :drafts, :files, :settings] do
    assigns = assign(assigns, :visible_section, panel)

    ~H"""
    <.live_component
      module={LibrarySidebarComponent}
      id={"rail-#{@visible_section}"}
      current_user={@current_user}
      conversation_id={@conversation_id}
      folder_id={@folder_id}
      active_system_prompt={@active_system_prompt}
      conversation_drafts={@conversation_drafts}
      active_draft_id={@active_draft_id}
      visible_section={@visible_section}
      floating_mode={true}
      workspace_id={@workspace_id}
      active_page_id={@active_page_id}
    />
    """
  end

  defp render_panel_body(assigns), do: ~H""

  @impl true
  def handle_event("toggle_panel", %{"panel" => panel}, socket) do
    panel_atom = String.to_existing_atom(panel)
    next = if socket.assigns.open_panel == panel_atom, do: nil, else: panel_atom

    socket =
      if next, do: ensure_panel_data(socket), else: socket

    {:noreply, assign(socket, :open_panel, next)}
  end

  def handle_event("select_panel", %{"panel" => panel}, socket) do
    panel_atom = String.to_existing_atom(panel)

    {:noreply,
     socket
     |> ensure_panel_data()
     |> assign(:open_panel, panel_atom)}
  end

  def handle_event("close_panel", _params, socket) do
    {:noreply, assign(socket, :open_panel, nil)}
  end

  defp visible?(:always, _), do: true
  defp visible?(:conversation, %{conversation_id: id}), do: not is_nil(id)
  defp visible?(:has_jobs, %{has_jobs: true}), do: true
  defp visible?(_, _), do: false

  defp ensure_panel_data(%{assigns: %{panel_data_loaded?: true}} = socket), do: socket

  defp ensure_panel_data(socket) do
    user = ensure_current_user(socket.assigns)
    data = load_panel_data(socket.assigns.conversation_id, user)

    socket
    |> assign(:current_user, user)
    |> assign(:folder_id, data.folder_id)
    |> assign(:active_system_prompt, data.active_system_prompt)
    |> assign(:conversation_drafts, data.conversation_drafts)
    |> assign(:active_draft_id, data.active_draft_id)
    |> assign(:active_page_id, data.active_page_id)
    |> assign(:panel_data_loaded?, true)
  end

  defp ensure_current_user(%{current_user: %{} = user}), do: user

  defp ensure_current_user(%{user_id: user_id}),
    do: Magus.Accounts.get_user!(user_id, authorize?: false)

  defp load_panel_data(conv_id, user) when is_binary(conv_id) do
    conv =
      case Magus.Chat.get_conversation(conv_id, actor: user, load: [:active_system_prompt]) do
        {:ok, c} -> c
        _ -> nil
      end

    %{
      folder_id: conv && conv.folder_id,
      active_system_prompt: conv && conv.active_system_prompt,
      conversation_drafts: list_drafts(conv_id, user),
      active_draft_id: nil,
      active_page_id: nil
    }
  end

  defp load_panel_data(_conv_id, _user) do
    %{
      folder_id: nil,
      active_system_prompt: nil,
      conversation_drafts: [],
      active_draft_id: nil,
      active_page_id: nil
    }
  end

  defp list_drafts(conv_id, user) do
    case Magus.Drafts.list_drafts_for_conversation(conv_id, actor: user) do
      {:ok, drafts} -> drafts
      _ -> []
    end
  end
end
