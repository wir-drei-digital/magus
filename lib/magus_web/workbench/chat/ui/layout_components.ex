defmodule MagusWeb.ChatLive.UI.LayoutComponents do
  @moduledoc """
  Layout components for the ChatLive interface.

  Contains template components for:
  - Mobile headers and sidebars
  - Desktop sidebars (conversation list, library sidebar)
  - Conversation info display
  """

  use MagusWeb, :html

  alias MagusWeb.ChatLive.Components.Library.LibrarySidebarComponent
  alias MagusWeb.ChatLive.Components.Conversations.ConversationListComponent
  alias MagusWeb.ChatLive.Components.WorkspaceSelectorComponent

  alias MagusWeb.ChatLive.Components.Participants.ParticipantsSidebarComponent

  # ============================================================================
  # Pill Button
  # ============================================================================

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :click, :string, required: true
  attr :title, :string, default: nil

  def pill_button(assigns) do
    ~H"""
    <button
      type="button"
      class="flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium rounded-full bg-base-200 hover:bg-base-300 transition-colors"
      phx-click={@click}
      title={@title || @label}
    >
      <.icon name={@icon} class="w-4 h-4" />
      <span>{@label}</span>
    </button>
    """
  end

  # ============================================================================
  # Mobile Header
  # ============================================================================

  attr :conversation, :map, default: nil
  attr :sidebar_state, :map, required: true

  def mobile_header(assigns) do
    ~H"""
    <div class="flex items-center h-12 px-4 border-b border-base-300 md:hidden bg-base-100/80 backdrop-blur-sm sticky top-0 z-20">
      <.pill_button
        icon="lucide-menu"
        label={gettext("Menu")}
        click="toggle_mobile_left_sidebar"
      />
      <div class="flex-1 text-center font-medium truncate px-4">
        <%= if @conversation do %>
          {@conversation.title || gettext("Untitled conversation")}
        <% else %>
          {gettext("New Chat")}
        <% end %>
      </div>
      <.pill_button
        icon="lucide-more-horizontal"
        label={gettext("More")}
        click="toggle_mobile_right_sidebar"
      />
    </div>
    """
  end

  # ============================================================================
  # Mobile Left Sidebar
  # ============================================================================

  attr :folders, :list, required: true
  attr :unfiled_conversations, :list, required: true
  attr :team_conversations, :list, default: []
  attr :expanded_folders, :map, required: true
  attr :conversation, :map, default: nil
  attr :current_user, :map, required: true
  attr :favorite_conversations, :list, default: []
  attr :favorites_collapsed, :boolean, default: false
  attr :workspaces, :list, default: []
  attr :current_workspace, :map, default: nil
  attr :can_create_workspace, :boolean, default: false

  def mobile_left_sidebar(assigns) do
    nav_items = MagusWeb.Layouts.nav_items()
    assigns = assign(assigns, :nav_items, nav_items)

    ~H"""
    <div class="fixed inset-0 z-50 md:hidden">
      <%!-- Backdrop with blur --%>
      <div
        class="absolute inset-0 bg-base-content/20 backdrop-blur-sm"
        phx-click="toggle_mobile_left_sidebar"
      />
      <%!-- Sidebar Panel --%>
      <div class="absolute left-0 top-0 bottom-0 w-80 max-w-[85vw] bg-base-100 shadow-xl overflow-hidden flex flex-col mobile-sidebar-left">
        <%!-- Header with Logo --%>
        <div class="flex items-center justify-between h-14 px-4 border-b border-base-300">
          <a href="/" class="flex items-end gap-2 font-semibold">
            <span class="text-primary text-3xl leading-none">◬</span>
            <span class="text-base-content font-logo">MAGUS</span>
          </a>
          <button
            type="button"
            class="icon-btn"
            phx-click="toggle_mobile_left_sidebar"
          >
            <.icon name="lucide-x" class="w-5 h-5" />
          </button>
        </div>

        <%!-- Search bar --%>
        <div class="p-4 border-b border-base-300">
          <form action="/search" method="get">
            <div class="relative">
              <.icon
                name="lucide-search"
                class="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-base-content/40"
              />
              <input
                type="text"
                name="q"
                placeholder={gettext("Search...")}
                class="w-full pl-9 pr-3 py-2 text-sm bg-base-200 border border-base-300 rounded-lg"
              />
            </div>
          </form>
        </div>

        <%!-- Main menu items --%>
        <nav class="p-2 border-b border-base-300">
          <a
            :for={item <- @nav_items}
            href={item.href}
            class="flex items-center gap-3 px-3 py-2.5 text-sm font-medium text-base-content/70 hover:text-base-content hover:bg-base-200 rounded-lg"
          >
            <.icon name={item.icon} class="w-5 h-5" />
            {item.label}
          </a>
        </nav>

        <%!-- Workspace Selector (mobile) --%>
        <div
          :if={@workspaces != [] or @can_create_workspace}
          class="px-3 py-2 border-b border-base-300"
        >
          <.live_component
            module={WorkspaceSelectorComponent}
            id="mobile-workspace-selector"
            workspaces={@workspaces}
            current_workspace={@current_workspace}
            can_create_workspace={@can_create_workspace}
          />
        </div>

        <%!-- Conversation list --%>
        <div class="flex-1 overflow-y-auto">
          <.live_component
            module={ConversationListComponent}
            id="mobile-conversation-list"
            folders={@folders}
            unfiled_conversations={@unfiled_conversations}
            team_conversations={@team_conversations}
            expanded_folders={@expanded_folders}
            current_conversation_id={@conversation && @conversation.id}
            current_user={@current_user}
            hide_header={true}
            favorite_conversations={@favorite_conversations}
            favorites_collapsed={@favorites_collapsed}
            current_workspace={@current_workspace}
            workspaces={@workspaces}
            can_create_workspace={@can_create_workspace}
          />
        </div>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Mobile Right Sidebar
  # ============================================================================

  attr :conversation, :map, default: nil
  attr :current_user, :map, required: true
  attr :active_system_prompt, :map, default: nil
  attr :conversation_drafts, :list, default: []
  attr :active_draft, :map, default: nil
  attr :current_workspace, :map, default: nil

  def mobile_right_sidebar(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 md:hidden">
      <%!-- Backdrop with blur --%>
      <div
        class="absolute inset-0 bg-base-content/20 backdrop-blur-sm"
        phx-click="toggle_mobile_right_sidebar"
      />
      <%!-- Sidebar Panel - transparent background --%>
      <div class="absolute right-0 top-0 bottom-0 w-80 max-w-[85vw] overflow-hidden flex flex-col mobile-sidebar-right">
        <%!-- Close button - right aligned at top --%>
        <div class="flex justify-end p-3">
          <button
            type="button"
            class="w-9 h-9 flex items-center justify-center rounded-full bg-white text-black dark:bg-black dark:text-white shadow-lg"
            phx-click="toggle_mobile_right_sidebar"
          >
            <.icon name="lucide-x" class="w-5 h-5" />
          </button>
        </div>
        <%!-- Library Sidebar Content --%>
        <div class="flex-1 overflow-hidden">
          <.live_component
            module={LibrarySidebarComponent}
            id="mobile-library-sidebar"
            current_user={@current_user}
            conversation_id={@conversation && @conversation.id}
            folder_id={@conversation && @conversation.folder_id}
            active_system_prompt={@active_system_prompt}
            conversation_drafts={@conversation_drafts}
            active_draft_id={@active_draft && @active_draft.id}
            workspace_id={@current_workspace && @current_workspace.id}
          />
        </div>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Conversation Sidebar (Desktop Left)
  # ============================================================================

  attr :sidebar_collapsed, :boolean, required: true
  attr :folders, :list, required: true
  attr :unfiled_conversations, :list, required: true
  attr :team_conversations, :list, default: []
  attr :expanded_folders, :map, required: true
  attr :conversation, :map, default: nil
  attr :current_user, :map, required: true
  attr :favorite_conversations, :list, default: []
  attr :favorites_collapsed, :boolean, default: false
  attr :workspaces, :list, default: []
  attr :current_workspace, :map, default: nil
  attr :can_create_workspace, :boolean, default: false
  attr :threads_by_conversation, :map, default: %{}
  attr :active_thread, :map, default: nil

  def conversation_sidebar(assigns) do
    ~H"""
    <div class={[
      "hidden md:flex fixed left-0 top-14 bottom-0 z-10 transition-all duration-200 p-3 pr-0 overflow-hidden",
      if(@sidebar_collapsed, do: "w-16", else: "w-80")
    ]}>
      <%= if @sidebar_collapsed do %>
        <div class="w-full flex flex-col items-center gap-2">
          <button
            type="button"
            class="icon-btn"
            phx-click="toggle_sidebar_collapse"
            title={gettext("Expand sidebar")}
          >
            <.icon name="lucide-chevrons-right" class="w-5 h-5" />
          </button>
          <.link
            navigate={~p"/chat"}
            class="flex items-center justify-center bg-primary hover:bg-primary/80 rounded-full p-1.5 transition-colors"
            title={gettext("New Chat")}
          >
            <.icon name="lucide-plus" class="w-5 h-5 text-white" />
          </.link>
        </div>
      <% else %>
        <div class="w-full overflow-hidden h-full flex flex-col">
          <%!-- Conversation List --%>
          <div class="flex-1 overflow-hidden">
            <.live_component
              module={ConversationListComponent}
              id="conversation-list"
              folders={@folders}
              unfiled_conversations={@unfiled_conversations}
              team_conversations={@team_conversations}
              expanded_folders={@expanded_folders}
              current_conversation_id={@conversation && @conversation.id}
              current_user={@current_user}
              favorite_conversations={@favorite_conversations}
              favorites_collapsed={@favorites_collapsed}
              current_workspace={@current_workspace}
              workspaces={@workspaces}
              can_create_workspace={@can_create_workspace}
              threads_by_conversation={@threads_by_conversation}
              active_thread={@active_thread}
            />
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Right Sidebar (Desktop)
  # ============================================================================

  attr :right_sidebar, :atom, default: nil
  attr :right_collapsed, :boolean, default: false
  attr :collapsed_panel, :atom, default: nil
  attr :conversation, :map, default: nil
  attr :conversation_agent, :map, default: nil
  attr :current_user, :map, required: true
  attr :members, :list, default: []
  attr :is_conversation_owner, :boolean, default: false
  attr :editing_title, :boolean, default: false
  attr :active_system_prompt, :map, default: nil
  attr :conversation_drafts, :list, default: []
  attr :active_draft, :map, default: nil
  attr :has_active_share_links, :boolean, default: false
  attr :is_favorited, :boolean, default: false
  attr :has_jobs, :boolean, default: false
  attr :current_workspace, :map, default: nil
  attr :active_page_id, :string, default: nil

  def right_sidebar(assigns) do
    show_participants =
      assigns.right_sidebar == :participants &&
        assigns.conversation && assigns.conversation.is_multiplayer

    agent = assigns.conversation_agent

    assigns =
      assigns
      |> assign(:show_participants, show_participants)
      |> assign(:agent, agent)

    ~H"""
    <div class={[
      "fixed right-0 top-14 bottom-0 p-3 pl-0 z-10 overflow-hidden",
      if(@right_collapsed, do: "w-16", else: "w-80"),
      if(@right_sidebar, do: "flex", else: "hidden md:flex")
    ]}>
      <%= if @right_collapsed do %>
        <%!-- Collapsed: Show toggle button and icon buttons that open floating panels --%>
        <div class="w-full flex flex-col items-center gap-2">
          <button
            type="button"
            class="icon-btn"
            phx-click="toggle_right_sidebar_collapse"
            title={gettext("Expand sidebar")}
          >
            <.icon name="lucide-chevrons-left" class="w-5 h-5" />
          </button>
          <.link
            :if={@agent}
            navigate={~p"/agents/#{@agent.id}"}
            class="tooltip tooltip-left"
            data-tip={@agent.name}
          >
            <%= if @agent.image_url do %>
              <img
                src={@agent.image_url}
                class="w-8 h-8 rounded-full object-cover"
                alt={@agent.name}
              />
            <% else %>
              <span class="text-xl leading-none">{@agent.icon || "🤖"}</span>
            <% end %>
          </.link>
          <button
            :if={@conversation && @is_conversation_owner}
            type="button"
            class="icon-btn"
            phx-click="toggle_favorite"
            title={
              if @is_favorited,
                do: gettext("Remove from favorites"),
                else: gettext("Add to favorites")
            }
          >
            <.icon
              name="lucide-star"
              class={["w-5 h-5", @is_favorited && "fill-warning text-warning"]}
            />
          </button>
          <div class="h-px bg-base-300 w-8 my-1" />
          <button
            type="button"
            class={"icon-btn #{if @collapsed_panel == :prompts, do: "active"}"}
            phx-click="toggle_collapsed_panel"
            phx-value-panel="prompts"
            title={gettext("Prompts")}
          >
            <.icon name="lucide-puzzle" class="w-5 h-5" />
          </button>
          <button
            type="button"
            class={"icon-btn #{if @collapsed_panel == :brains, do: "active"}"}
            phx-click="toggle_collapsed_panel"
            phx-value-panel="brains"
            title={gettext("Brains")}
          >
            <.icon name="lucide-brain" class="w-5 h-5" />
          </button>
          <button
            :if={@conversation}
            type="button"
            class={"icon-btn #{if @collapsed_panel == :drafts, do: "active"}"}
            phx-click="toggle_collapsed_panel"
            phx-value-panel="drafts"
            title={gettext("Drafts")}
          >
            <.icon name="lucide-file-text" class="w-5 h-5" />
          </button>
          <button
            type="button"
            class={"icon-btn #{if @collapsed_panel == :files, do: "active"}"}
            phx-click="toggle_collapsed_panel"
            phx-value-panel="files"
            title={gettext("Files")}
          >
            <.icon name="lucide-database" class="w-5 h-5" />
          </button>
          <button
            type="button"
            class={"icon-btn #{if @collapsed_panel == :settings, do: "active"}"}
            phx-click="toggle_collapsed_panel"
            phx-value-panel="settings"
            title={gettext("Settings")}
          >
            <.icon name="lucide-settings" class="w-5 h-5" />
          </button>
          <button
            :if={@conversation && @has_jobs}
            type="button"
            class={"icon-btn #{if @collapsed_panel == :jobs, do: "active"}"}
            phx-click="toggle_collapsed_panel"
            phx-value-panel="jobs"
            title={gettext("Jobs")}
          >
            <.icon name="lucide-clock" class="w-5 h-5" />
          </button>
        </div>

        <%!-- Floating panel overlay when collapsed --%>
        <div
          :if={@collapsed_panel}
          class="fixed right-16 top-14 w-80 p-3 z-20 max-h-[calc(100vh-4rem)]"
        >
          <%!-- Close button positioned above card --%>
          <%!-- <div class="flex justify-end mb-2">
            <button
              type="button"
              class="icon-btn bg-base-100 rounded-full shadow"
              phx-click="close_collapsed_panel"
              title={gettext("Close")}
            >
              <.icon name="lucide-x" class="w-4 h-4" />
            </button>
          </div> --%>

          <%!-- Panel content: reuse LibrarySidebarComponent with visible_section --%>
          <div class="max-h-[calc(100vh-8rem)]">
            <.live_component
              module={LibrarySidebarComponent}
              id={"collapsed-panel-#{@collapsed_panel}"}
              current_user={@current_user}
              conversation_id={@conversation && @conversation.id}
              folder_id={@conversation && @conversation.folder_id}
              active_system_prompt={@active_system_prompt}
              conversation_drafts={@conversation_drafts}
              active_draft_id={@active_draft && @active_draft.id}
              visible_section={@collapsed_panel}
              floating_mode={true}
              workspace_id={@current_workspace && @current_workspace.id}
              active_page_id={@active_page_id}
            />
          </div>
        </div>
      <% else %>
        <%!-- Expanded: Full sidebar content --%>
        <div class="w-full overflow-visible h-full flex flex-col gap-3">
          <%!-- Collapse button --%>
          <div class="flex justify-end px-2">
            <button
              type="button"
              class="icon-btn"
              phx-click="toggle_right_sidebar_collapse"
              title={gettext("Collapse sidebar")}
            >
              <.icon name="lucide-chevrons-right" class="w-5 h-5" />
            </button>
          </div>

          <%!-- Conversation Info --%>
          <.conversation_info
            :if={@conversation}
            conversation={@conversation}
            agent={@agent}
            current_user={@current_user}
            is_conversation_owner={@is_conversation_owner}
            editing_title={@editing_title}
            has_active_share_links={@has_active_share_links}
            is_favorited={@is_favorited}
          />

          <%!-- Participants Sidebar: always mounted for multiplayer so modal events can reach it --%>
          <div
            :if={@conversation && @conversation.is_multiplayer}
            class={if @show_participants, do: "flex-1 overflow-hidden", else: "hidden"}
          >
            <.live_component
              module={ParticipantsSidebarComponent}
              id="participants-sidebar"
              current_user={@current_user}
              conversation_id={@conversation.id}
              members={@members}
              is_owner={@is_conversation_owner}
            />
          </div>
          <%!-- Library Sidebar (default when right sidebar is open but not showing participants) --%>
          <div :if={!@show_participants} class="flex-1 overflow-hidden">
            <.live_component
              module={LibrarySidebarComponent}
              id="library-sidebar"
              current_user={@current_user}
              conversation_id={@conversation && @conversation.id}
              folder_id={@conversation && @conversation.folder_id}
              active_system_prompt={@active_system_prompt}
              conversation_drafts={@conversation_drafts}
              active_draft_id={@active_draft && @active_draft.id}
              workspace_id={@current_workspace && @current_workspace.id}
              active_page_id={@active_page_id}
            />
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ============================================================================
  # Conversation Info
  # ============================================================================

  attr :conversation, :map, required: true
  attr :agent, :map, default: nil
  attr :current_user, :map, required: true
  attr :is_conversation_owner, :boolean, default: false
  attr :editing_title, :boolean, default: false
  attr :has_active_share_links, :boolean, default: false
  attr :is_favorited, :boolean, default: false

  def conversation_info(assigns) do
    ~H"""
    <div class="px-2 pb-3 border-b border-base-300 flex flex-col gap-3">
      <%!-- Editable Title --%>
      <%= if @editing_title do %>
        <form phx-submit="save_title" class="flex gap-2">
          <input
            type="text"
            name="title"
            value={@conversation.title || ""}
            class="input input-sm input-bordered flex-1"
            placeholder={gettext("Conversation title")}
            autofocus
          />
          <button type="submit" class="btn btn-sm btn-primary">
            <.icon name="lucide-check" class="w-4 h-4" />
          </button>
          <button type="button" class="btn btn-sm btn-ghost" phx-click="cancel_edit_title">
            <.icon name="lucide-x" class="w-4 h-4" />
          </button>
        </form>
      <% else %>
        <h2
          class={[
            "text-base font-medium break-words",
            @is_conversation_owner && "cursor-pointer hover:text-primary transition-colors"
          ]}
          phx-click={@is_conversation_owner && "start_edit_title"}
          title={gettext("Click to edit title")}
        >
          {@conversation.title || gettext("Untitled conversation")}
        </h2>
      <% end %>

      <%!-- Metadata --%>
      <div class="flex flex-col gap-1.5 text-xs text-base-content/60">
        <div class="flex items-center gap-2">
          <.icon name="lucide-calendar" class="w-3.5 h-3.5" />
          <span>{gettext("Created")} {format_relative_time(@conversation.inserted_at)}</span>
        </div>
        <div class="flex items-center gap-2">
          <.icon name="lucide-clock" class="w-3.5 h-3.5" />
          <span>{gettext("Updated")} {format_relative_time(@conversation.updated_at)}</span>
        </div>
        <div class="flex items-center gap-2">
          <.icon name="lucide-messages-square" class="w-3.5 h-3.5" />
          <span>{ngettext("1 message", "%{count} messages", get_message_count(@conversation))}</span>
        </div>
      </div>

      <%!-- Custom Agent --%>
      <.link
        :if={@agent}
        navigate={~p"/agents/#{@agent.id}"}
        class="flex items-center gap-2.5 p-2 -mx-2 rounded-lg hover:bg-base-200 transition-colors group"
      >
        <%= if @agent.image_url do %>
          <img
            src={@agent.image_url}
            class="w-8 h-8 rounded-full object-cover flex-shrink-0"
            alt={@agent.name}
          />
        <% else %>
          <span class="w-8 h-8 rounded-full bg-base-300 flex items-center justify-center text-base flex-shrink-0">
            {@agent.icon || "🤖"}
          </span>
        <% end %>
        <div class="min-w-0">
          <div class="text-sm font-medium truncate group-hover:text-primary transition-colors">
            {@agent.name}
          </div>
          <div :if={@agent.handle} class="text-xs text-base-content/50 truncate">
            @{@agent.handle}
          </div>
        </div>
      </.link>

      <%!-- Badges --%>
      <div class="flex flex-wrap gap-1.5">
        <span :if={@conversation.is_multiplayer} class="badge badge-sm badge-primary gap-1">
          <.icon name="lucide-users" class="w-3 h-3" /> {gettext("Multiplayer")}
        </span>
        <span :if={@has_active_share_links} class="badge badge-sm badge-success gap-1">
          <.icon name="lucide-globe" class="w-3 h-3" /> {gettext("Shared")}
        </span>
      </div>

      <%!-- Actions --%>
      <div class="flex items-center gap-1">
        <button
          :if={@is_conversation_owner}
          class="btn btn-outline btn-sm btn-square"
          phx-click="toggle_favorite"
          title={
            if @is_favorited, do: gettext("Remove from favorites"), else: gettext("Add to favorites")
          }
        >
          <.icon
            name="lucide-star"
            class={["w-3.5 h-3.5", @is_favorited && "fill-warning text-warning"]}
          />
        </button>
        <button
          :if={@is_conversation_owner}
          class="btn btn-outline btn-sm gap-1"
          phx-click="show_share_modal"
          title={gettext("Share")}
        >
          <.icon name="lucide-share-2" class="w-3.5 h-3.5" />
          <span class="text-xs">{gettext("Share")}</span>
        </button>
        <button
          :if={@conversation && @conversation.is_multiplayer}
          class="btn btn-outline btn-sm gap-1"
          phx-click="toggle_participants_sidebar"
          title={gettext("Participants")}
        >
          <.icon name="lucide-users" class="w-3.5 h-3.5" />
          <span class="text-xs">{gettext("Participants")}</span>
        </button>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp get_message_count(%{message_count: count}) when is_integer(count), do: count
  defp get_message_count(_), do: 0

  defp format_relative_time(datetime) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, datetime, :second)

    cond do
      diff_seconds < 60 ->
        gettext("just now")

      diff_seconds < 3600 ->
        ngettext("1 min ago", "%{count} mins ago", div(diff_seconds, 60))

      diff_seconds < 86400 ->
        ngettext("1 hour ago", "%{count} hours ago", div(diff_seconds, 3600))

      diff_seconds < 604_800 ->
        ngettext("1 day ago", "%{count} days ago", div(diff_seconds, 86400))

      true ->
        Calendar.strftime(datetime, "%b %d, %Y")
    end
  end
end
