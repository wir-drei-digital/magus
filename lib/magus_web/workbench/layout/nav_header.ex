defmodule MagusWeb.Workbench.Layout.NavHeader do
  @moduledoc """
  Top-of-nav-pane chrome: workspace selector (always), plus
  All/Shared/Personal filter + Search button + mode-specific CTAs for
  tabbed modes (chat, brain, files). Agents/Prompts render only the
  workspace selector; their nav components handle their own listing.

  The filter row is suppressed in the Personal workspace (workspace_id
  is nil) because there is no shared/personal split to apply: personal
  workspace shows the actor's no-workspace resources as a single list.

  Events emitted to parent LiveView:
    - `select_workspace`, `open_create_workspace` (from WorkspaceSelector)
    - `set_nav_filter` with `phx-value-filter=<all|shared|personal>`
    - `new_chat` click

  The Search button calls `window.GlobalSearch.open()` directly via JS.
  """
  use MagusWeb, :live_component

  alias MagusWeb.Workbench.Layout.WorkspaceSelector

  @filters [
    %{key: :all, label: "All"},
    %{key: :shared, label: "Shared"},
    %{key: :personal, label: "Personal"}
  ]

  @tabbed_modes [:chat, :brain, :files]
  @filterable_modes [:chat, :brain, :files, :agents, :prompts]

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:detail_view, fn -> nil end)
      |> assign(:filters, @filters)
      |> assign(:tabbed_mode?, assigns.current_mode in @tabbed_modes)
      |> assign(:filterable_mode?, assigns.current_mode in @filterable_modes)
      |> assign(:in_workspace?, not is_nil(assigns.current_workspace))

    ~H"""
    <header data-nav-header class="flex flex-col">
      <.live_component
        module={WorkspaceSelector}
        id={"#{@id}-workspace-selector"}
        current_user={@current_user}
        current_workspace={@current_workspace}
        workspaces={@workspaces}
      />

      <div :if={@tabbed_mode? or @current_mode in [:agents, :prompts]} class="px-2 pb-2">
        <button
          type="button"
          data-search-button
          onclick="window.GlobalSearch && window.GlobalSearch.open()"
          class="w-full flex items-center gap-2 px-2 py-1.5 text-sm rounded-md text-wb-text-secondary hover:bg-wb-hover transition-colors"
        >
          <.icon name="lucide-search" class="w-4 h-4" />
          <span>Search</span>
          <kbd class="ml-auto text-xs px-1.5 py-0.5 bg-wb-surface-2 rounded border border-wb-border">
            <span class="[[data-os=other]_&]:hidden">⌘K</span>
            <span class="hidden [[data-os=other]_&]:inline">Ctrl K</span>
          </kbd>
        </button>
      </div>

      <div
        :if={@current_mode == :chat and is_nil(@detail_view)}
        class="flex flex-col gap-0.5 px-2 pb-2"
      >
        <button
          type="button"
          phx-click="open_tab"
          phx-value-type="conversation"
          phx-value-id="new"
          phx-value-label="New chat"
          data-new-chat
          class="flex items-center gap-2 px-2 py-1.5 text-sm rounded-md text-wb-text-secondary hover:bg-wb-hover hover:text-wb-text transition-colors"
        >
          <.icon name="lucide-plus" class="w-4 h-4 shrink-0" />
          <span>New chat</span>
        </button>
        <button
          type="button"
          phx-click="begin_new_folder"
          class="flex items-center gap-2 px-2 py-1.5 text-sm rounded-md text-wb-text-secondary hover:bg-wb-hover hover:text-wb-text transition-colors"
        >
          <.icon name="lucide-folder-plus" class="w-4 h-4 shrink-0" />
          <span>New folder</span>
        </button>
      </div>

      <div
        :if={@current_mode == :brain and is_nil(@detail_view)}
        class="flex flex-col gap-0.5 px-2 pb-2"
      >
        <button
          type="button"
          phx-click="begin_new_brain"
          data-new-brain
          class="flex items-center gap-2 px-2 py-1.5 text-sm rounded-md text-wb-text-secondary hover:bg-wb-hover hover:text-wb-text transition-colors"
        >
          <.icon name="lucide-plus" class="w-4 h-4 shrink-0" />
          <span>New brain</span>
        </button>
      </div>

      <div
        :if={@current_mode == :agents and is_nil(@detail_view)}
        class="flex flex-col gap-0.5 px-2 pb-2"
      >
        <button
          type="button"
          phx-click="new_agent"
          data-new-agent
          class="flex items-center gap-2 px-2 py-1.5 text-sm rounded-md text-wb-text-secondary hover:bg-wb-hover hover:text-wb-text transition-colors"
        >
          <.icon name="lucide-plus" class="w-4 h-4 shrink-0" />
          <span>New agent</span>
        </button>
      </div>

      <div
        :if={@current_mode == :prompts and is_nil(@detail_view)}
        class="flex flex-col gap-0.5 px-2 pb-2"
      >
        <button
          type="button"
          phx-click="new_prompt"
          data-new-prompt
          class="flex items-center gap-2 px-2 py-1.5 text-sm rounded-md text-wb-text-secondary hover:bg-wb-hover hover:text-wb-text transition-colors"
        >
          <.icon name="lucide-plus" class="w-4 h-4 shrink-0" />
          <span>New prompt</span>
        </button>
        <.link
          navigate={~p"/prompts"}
          data-prompt-library-link
          class="flex items-center gap-2 px-2 py-1.5 text-sm rounded-md text-wb-text-secondary hover:bg-wb-hover hover:text-wb-text transition-colors"
        >
          <.icon name="lucide-globe" class="w-4 h-4 shrink-0" />
          <span>Public library</span>
        </.link>
      </div>

      <div
        :if={
          @filterable_mode? and @in_workspace? and @current_mode != :files and
            is_nil(@detail_view)
        }
        class="flex items-center gap-1 px-3 py-2"
      >
        <button
          :for={filter <- @filters}
          type="button"
          data-nav-filter={filter.key}
          phx-click="set_nav_filter"
          phx-value-filter={filter.key}
          class={[
            "px-2.5 py-1 text-xs rounded-full transition-colors",
            if(@nav_filter == filter.key,
              do: "bg-wb-surface-2 text-wb-text",
              else: "text-wb-text-muted hover:bg-wb-hover"
            )
          ]}
        >
          {filter.label}
        </button>
      </div>
    </header>
    """
  end
end
