defmodule MagusWeb.Workbench.Resources.FileBrowserView.TopBar do
  @moduledoc false
  use MagusWeb, :live_component

  alias Phoenix.LiveView.JS

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:sort_options, sort_labels())}
  end

  defp sort_labels do
    [
      {"updated_at:desc", gettext("Modified ↓")},
      {"updated_at:asc", gettext("Modified ↑")},
      {"name:asc", gettext("Name A→Z")},
      {"name:desc", gettext("Name Z→A")},
      {"file_size:desc", gettext("Size ↓")},
      {"file_size:asc", gettext("Size ↑")}
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="file-browser-topbar h-12 flex items-center gap-3 md:px-3 px-14 border-b border-wb-border">
      <div class="flex items-center gap-1 text-sm min-w-0 truncate flex-1">
        <%= for {crumb, idx} <- Enum.with_index(@breadcrumbs) do %>
          <%= if idx > 0 do %>
            <span class="text-wb-text-dim mx-1">›</span>
          <% end %>
          <button
            type="button"
            phx-click="navigate_breadcrumb"
            phx-value-path={crumb.path}
            class="hover:underline truncate"
          >
            {crumb.label}
          </button>
        <% end %>
      </div>

      <form phx-submit="search" phx-change="search_input" class="flex items-center">
        <input
          type="text"
          name="q"
          value={@q}
          placeholder={gettext("Search...")}
          phx-debounce="250"
          class="bg-wb-surface border border-wb-border rounded-md px-2 py-1 text-xs w-40 focus:outline-none focus:ring-1 focus:ring-wb-accent"
        />
      </form>

      <div :if={can_create?(@scope)} class="flex items-center gap-1">
        <button type="button" phx-click="start_new_folder" class="wb-pill-btn">
          <.icon name="lucide-folder-plus" class="w-4 h-4" /> {gettext("New folder")}
        </button>

        <form
          id={"#{@id}-upload-form"}
          phx-change="validate_upload"
          phx-submit="validate_upload"
          phx-target={nil}
          class="contents"
        >
          <label class="wb-pill-btn cursor-pointer">
            <.icon name="lucide-upload" class="w-4 h-4" /> {gettext("Upload")}
            <.live_file_input upload={@upload_config.files} class="hidden" />
          </label>
        </form>
      </div>

      <form phx-change="set_sort" class="contents">
        <select name="sort" class="wb-pill-select">
          <option :for={{value, label} <- @sort_options} value={value} selected={value == @sort}>
            {label}
          </option>
        </select>
      </form>

      <div class="inline-flex border border-wb-border rounded-md overflow-hidden text-xs">
        <button
          type="button"
          phx-click={JS.push("set_view_mode", value: %{mode: "list"})}
          class={["px-2 py-1", @view_mode == "list" && "bg-wb-accent/20 text-wb-accent"]}
          title={gettext("List view")}
          aria-label={gettext("List view")}
        >
          <.icon name="lucide-list" class="w-4 h-4" />
        </button>
        <button
          type="button"
          phx-click={JS.push("set_view_mode", value: %{mode: "grid"})}
          class={["px-2 py-1", @view_mode == "grid" && "bg-wb-accent/20 text-wb-accent"]}
          title={gettext("Grid view")}
          aria-label={gettext("Grid view")}
        >
          <.icon name="lucide-grid" class="w-4 h-4" />
        </button>
      </div>
    </div>
    """
  end

  defp can_create?(scope) when scope in ["my_files", "folder", "shared"], do: true
  defp can_create?(_), do: false
end
