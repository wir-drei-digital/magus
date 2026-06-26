defmodule MagusWeb.Workbench.Layout.NavPane do
  @moduledoc """
  Mode-aware wrapper that renders:
    1. A shared NavHeader (workspace selector + filter + search + new chat)
    2. The detail-view sub-nav (when @detail_view is set), or
       the current mode's nav component (chat/brain/agents/prompts/files)
  """
  use MagusWeb, :live_component

  alias MagusWeb.Workbench.Layout.DetailNav
  alias MagusWeb.Workbench.Layout.NavHeader
  alias MagusWeb.Workbench.Modes
  alias MagusWeb.Workbench.Modes.AgentsModeNav
  alias MagusWeb.Workbench.Modes.BrainModeNav
  alias MagusWeb.Workbench.Modes.ChatModeNav
  alias MagusWeb.Workbench.Modes.FilesModeNav
  alias MagusWeb.Workbench.Modes.PromptsModeNav

  @_known_modes Modes.keys()
  @_handled_modes [:chat, :brain, :agents, :prompts, :files]

  unless MapSet.new(@_known_modes) == MapSet.new(@_handled_modes) do
    raise "MagusWeb.Workbench.Layout.NavPane: Modes.keys() drift — update case block"
  end

  @impl true
  def render(assigns) do
    assigns = assign_new(assigns, :active_browser_filters, fn -> %{} end)

    ~H"""
    <aside class="workbench-nav-pane h-full flex flex-col w-72 bg-wb-bg border-r border-wb-border">
      <.live_component
        module={NavHeader}
        id="nav-header"
        current_user={@current_user}
        current_mode={@current_mode}
        current_workspace={@current_workspace}
        workspaces={@workspaces}
        nav_filter={@nav_filter}
        search_query={@search_query}
        detail_view={@detail_view}
      />

      <div class="flex-1 min-h-0 overflow-hidden">
        <%= cond do %>
          <% @detail_view -> %>
            <.live_component
              module={DetailNav}
              id="detail-nav"
              detail_view={@detail_view}
              current_user={@current_user}
            />
          <% true -> %>
            <%= case @current_mode do %>
              <% :chat -> %>
                <.live_component
                  module={ChatModeNav}
                  id="chat-mode-nav"
                  current_user={@current_user}
                  workspace_id={@workspace_id}
                  nav_filter={@nav_filter}
                  search_query={@search_query}
                />
              <% :brain -> %>
                <.live_component
                  module={BrainModeNav}
                  id="brain-mode-nav"
                  current_user={@current_user}
                  workspace_id={@workspace_id}
                  nav_filter={@nav_filter}
                  search_query={@search_query}
                />
              <% :agents -> %>
                <.live_component
                  module={AgentsModeNav}
                  id="agents-mode-nav"
                  current_user={@current_user}
                  workspace_id={@workspace_id}
                  nav_filter={@nav_filter}
                />
              <% :prompts -> %>
                <.live_component
                  module={PromptsModeNav}
                  id="prompts-mode-nav"
                  current_user={@current_user}
                  workspace_id={@workspace_id}
                  nav_filter={@nav_filter}
                  search_query={@search_query}
                  current_chat_conv_id={assigns[:current_chat_conv_id]}
                />
              <% :files -> %>
                <.live_component
                  module={FilesModeNav}
                  id="files-mode-nav"
                  current_user={@current_user}
                  workspace_id={@workspace_id}
                  active_browser_filters={@active_browser_filters}
                />
            <% end %>
        <% end %>
      </div>
    </aside>
    """
  end
end
