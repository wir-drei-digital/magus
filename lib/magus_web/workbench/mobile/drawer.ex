defmodule MagusWeb.Workbench.Mobile.Drawer do
  @moduledoc """
  Mobile slide-in drawer. Composes the existing workbench navigation
  (workspace selector, mode picker, mode-aware NavHeader, current mode's
  nav, footer utilities) into a panel that slides in from the left.

  Stateless. The parent LV owns `drawer_open?` and emits `toggle_drawer`
  / `close_drawer` events. The drawer's interior re-uses the existing
  per-mode nav components — picking a conversation from inside the drawer
  triggers the existing `open_tab` parent handler. The parent additionally
  closes the drawer on `open_tab`, `select_detail`, and `select_workspace`
  (handled in WorkbenchLive event handlers).
  """
  use MagusWeb, :html

  alias MagusWeb.Workbench.Layout.{ModePicker, NavHeader}
  alias MagusWeb.Workbench.Modes

  alias MagusWeb.Workbench.Modes.{
    AgentsModeNav,
    BrainModeNav,
    ChatModeNav,
    FilesModeNav,
    PromptsModeNav
  }

  @_known_modes Modes.keys()
  @_handled_modes [:chat, :brain, :agents, :prompts, :files]

  unless MapSet.new(@_known_modes) == MapSet.new(@_handled_modes) do
    raise "MagusWeb.Workbench.Mobile.Drawer: Modes.keys() drift — update case block"
  end

  attr :open?, :boolean, required: true
  attr :current_user, :map, required: true
  attr :current_mode, :atom, required: true
  attr :current_workspace, :any, required: true
  attr :workspaces, :list, required: true
  attr :workspace_id, :any, required: true
  attr :nav_filter, :atom, required: true
  attr :search_query, :string, required: true
  attr :current_chat_conv_id, :string, default: nil

  def drawer(assigns) do
    ~H"""
    <%!-- Backdrop (visible only when open) --%>
    <div
      :if={@open?}
      data-mobile-drawer-backdrop
      phx-click="close_drawer"
      class="fixed inset-0 bg-black/50 z-40"
      aria-hidden="true"
    />

    <aside
      data-mobile-drawer
      class={[
        "fixed inset-y-0 left-0 z-50 w-[85%] max-w-[360px] bg-wb-bg border-r border-wb-border",
        "flex flex-col transition-transform duration-200 ease-out",
        @open? && "translate-x-0",
        !@open? && "-translate-x-full"
      ]}
      role="dialog"
      aria-modal="true"
      aria-label={gettext("Workbench navigation")}
      aria-hidden={to_string(!@open?)}
    >
      <%!--
        Inner LiveComponents are only mounted while the drawer is open
        to keep mounted-component count low on mobile when the drawer is
        idle. Inner nav child IDs are derived from the drawer's NavHeader
        / mode-nav `@id`, so they coexist fine with the desktop NavPane
        whenever both are mounted at once.
      --%>
      <%= if @open? do %>
        <div class="border-b border-wb-border py-2">
          <ModePicker.mode_picker current_mode={@current_mode} layout={:horizontal} />
        </div>

        <.live_component
          module={NavHeader}
          id="mobile-nav-header"
          current_user={@current_user}
          current_mode={@current_mode}
          current_workspace={@current_workspace}
          workspaces={@workspaces}
          nav_filter={@nav_filter}
          search_query={@search_query}
        />

        <div class="flex-1 min-h-0 overflow-hidden">
          <%= case @current_mode do %>
            <% :chat -> %>
              <.live_component
                module={ChatModeNav}
                id="mobile-chat-mode-nav"
                current_user={@current_user}
                workspace_id={@workspace_id}
                nav_filter={@nav_filter}
                search_query={@search_query}
              />
            <% :brain -> %>
              <.live_component
                module={BrainModeNav}
                id="mobile-brain-mode-nav"
                current_user={@current_user}
                workspace_id={@workspace_id}
                nav_filter={@nav_filter}
                search_query={@search_query}
              />
            <% :agents -> %>
              <.live_component
                module={AgentsModeNav}
                id="mobile-agents-mode-nav"
                current_user={@current_user}
                workspace_id={@workspace_id}
                nav_filter={@nav_filter}
              />
            <% :prompts -> %>
              <.live_component
                module={PromptsModeNav}
                id="mobile-prompts-mode-nav"
                current_user={@current_user}
                workspace_id={@workspace_id}
                nav_filter={@nav_filter}
                search_query={@search_query}
                current_chat_conv_id={@current_chat_conv_id}
              />
            <% :files -> %>
              <.live_component
                module={FilesModeNav}
                id="mobile-files-mode-nav"
                current_user={@current_user}
                workspace_id={@workspace_id}
                nav_filter={@nav_filter}
                search_query={@search_query}
              />
          <% end %>
        </div>

        <div data-drawer-footer class="border-t border-wb-border p-3 flex items-center gap-3">
          <span class="flex-1 text-xs text-wb-text-muted truncate">{@current_user.email}</span>
          <a
            href="/jobs"
            class="text-wb-text-muted hover:text-wb-text"
            aria-label={gettext("Scheduled Jobs")}
          >
            <.icon name="lucide-clock" class="w-4 h-4" />
          </a>
          <a
            href="/settings"
            class="text-wb-text-muted hover:text-wb-text"
            aria-label={gettext("Settings")}
          >
            <.icon name="lucide-settings" class="w-4 h-4" />
          </a>
          <a
            href="/sign-out"
            class="text-wb-text-muted hover:text-error"
            aria-label={gettext("Sign out")}
          >
            <.icon name="lucide-log-out" class="w-4 h-4" />
          </a>
        </div>
      <% end %>
    </aside>
    """
  end
end
