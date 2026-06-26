defmodule MagusWeb.ChatLive.Components.Brain.BrainSidebarComponent do
  @moduledoc """
  LiveComponent for the Brains sidebar tab.

  Displays a list of brains the current user has access to,
  with pages as expandable subitems under each brain.

  Events emitted to parent (via notify_parent):
  - `{:open_brain_page, brain_id, page_id}` - user clicked a page
  - `:create_brain` - user clicked "New Brain"
  - `{:create_page_in_brain, brain_id}` - user clicked "New page" within a brain
  """
  use MagusWeb, :live_component
  use MagusWeb.Live.Shared.ComponentUtils

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <%!-- Search --%>
      <div class="mb-2">
        <form phx-change="search_brains" phx-target={@myself}>
          <input
            type="text"
            name="query"
            value={@search_query}
            placeholder={gettext("Search brains...")}
            class="input input-sm input-bordered w-full"
            autocomplete="off"
            phx-debounce="300"
          />
        </form>
      </div>

      <%!-- Brain list --%>
      <div class="flex-1 overflow-y-auto overflow-x-hidden">
        <ul class="menu menu-md w-full overflow-hidden">
          <li :for={brain <- @filtered_brains} class="w-full overflow-hidden">
            <div class="group flex items-center w-full">
              <%= if @editing_brain_id == brain.id do %>
                <span :if={brain.icon} class="text-base shrink-0 ml-2">{brain.icon}</span>
                <span :if={!brain.icon} class="text-base shrink-0 ml-2">
                  <.icon name="lucide-brain" class="w-4 h-4" />
                </span>
                <form
                  phx-submit="save_brain_title"
                  phx-target={@myself}
                  class="flex-1 min-w-0 ml-2"
                >
                  <input type="hidden" name="brain-id" value={brain.id} />
                  <input
                    type="text"
                    name="title"
                    value={@editing_brain_title}
                    class="input input-xs input-bordered w-full text-sm font-medium"
                    phx-blur="save_brain_title"
                    phx-keydown="brain_title_keydown"
                    phx-target={@myself}
                    phx-mounted={JS.focus()}
                    id={"brain-title-input-#{brain.id}"}
                  />
                </form>
              <% else %>
                <button
                  type="button"
                  class="flex items-center gap-2 flex-1 min-w-0 w-full cursor-pointer rounded-lg"
                  phx-click="toggle_brain"
                  phx-value-brain-id={brain.id}
                  phx-target={@myself}
                >
                  <span :if={brain.icon} class="text-base shrink-0">{brain.icon}</span>
                  <span :if={!brain.icon} class="text-base shrink-0">
                    <.icon name="lucide-brain" class="w-4 h-4" />
                  </span>
                  <span class="flex-1 truncate text-left">{brain.title}</span>
                  <.icon
                    name={
                      if MapSet.member?(@expanded_brains, brain.id),
                        do: "lucide-chevron-down",
                        else: "lucide-chevron-right"
                    }
                    class="w-3 h-3 shrink-0 text-base-content/40"
                  />
                </button>
                <div class="opacity-0 group-hover:opacity-100 flex items-center gap-0.5 shrink-0">
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs btn-square"
                    phx-click="edit_brain"
                    phx-value-brain-id={brain.id}
                    phx-target={@myself}
                  >
                    <.icon name="lucide-pencil" class="w-3.5 h-3.5" />
                  </button>
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs btn-square text-error"
                    phx-click="delete_brain"
                    phx-value-brain-id={brain.id}
                    phx-target={@myself}
                  >
                    <.icon name="lucide-trash-2" class="w-3.5 h-3.5" />
                  </button>
                </div>
              <% end %>
            </div>

            <%!-- Pages within brain (tree) --%>
            <ul :if={MapSet.member?(@expanded_brains, brain.id)} class="pl-4">
              <.page_tree_nodes
                pages={root_pages(brain_pages(brain, @pages_by_brain))}
                pages_by_parent={group_by_parent(brain_pages(brain, @pages_by_brain))}
                brain_id={brain.id}
                active_page_id={@active_page_id}
                expanded_pages={@expanded_pages}
                current_user_id={@current_user.id}
                target={@myself}
              />

              <%!-- Add new page button --%>
              <li>
                <button
                  type="button"
                  class="btn btn-ghost btn-sm gap-1 w-full justify-start py-2 text-base-content/60 hover:text-base-content hover:bg-primary/80"
                  phx-click="create_page"
                  phx-value-brain-id={brain.id}
                  phx-target={@myself}
                >
                  <.icon name="lucide-plus" class="w-4 h-4" />
                  <span class="text-xs">{gettext("New page")}</span>
                </button>
              </li>
            </ul>
          </li>
        </ul>

        <div :if={@filtered_brains == []} class="px-4 py-6 text-center text-base-content/40 text-sm">
          <%= if @search_query != "" do %>
            {gettext("No brains matching \"%{query}\"", query: @search_query)}
          <% else %>
            {gettext("No brains yet")}
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  def mount(socket) do
    {:ok,
     socket
     |> assign(:brains, [])
     |> assign(:filtered_brains, [])
     |> assign(:pages_by_brain, %{})
     |> assign(:expanded_brains, MapSet.new())
     |> assign(:expanded_pages, MapSet.new())
     |> assign(:search_query, "")
     |> assign(:active_page_id, nil)
     |> assign(:editing_brain_id, nil)
     |> assign(:editing_brain_title, "")
     |> assign(:workspace_id, nil)}
  end

  def update(assigns, socket) do
    socket = assign(socket, :current_user, assigns.current_user)
    socket = assign(socket, :workspace_id, assigns[:workspace_id])
    new_active_page_id = assigns[:active_page_id]
    old_active_page_id = socket.assigns[:active_page_id]
    socket = assign(socket, :active_page_id, new_active_page_id)

    # Always reload brains so sidebar stays in sync after create/delete
    socket = load_brains(socket)

    socket =
      if new_active_page_id && new_active_page_id != old_active_page_id do
        expand_ancestors(socket, new_active_page_id)
      else
        socket
      end

    {:ok, socket}
  end

  # -- Events --

  def handle_event("search_brains", %{"query" => query}, socket) do
    filtered = filter_brains(socket.assigns.brains, query)
    {:noreply, socket |> assign(:search_query, query) |> assign(:filtered_brains, filtered)}
  end

  def handle_event("toggle_brain", %{"brain-id" => brain_id}, socket) do
    expanded = socket.assigns.expanded_brains

    expanded =
      if MapSet.member?(expanded, brain_id) do
        MapSet.delete(expanded, brain_id)
      else
        MapSet.put(expanded, brain_id)
      end

    # Load pages for the brain if expanding and not yet loaded
    socket =
      if MapSet.member?(expanded, brain_id) and
           not Map.has_key?(socket.assigns.pages_by_brain, brain_id) do
        load_pages_for_brain(socket, brain_id)
      else
        socket
      end

    {:noreply, assign(socket, :expanded_brains, expanded)}
  end

  def handle_event("open_page", %{"brain-id" => brain_id, "page-id" => page_id}, socket) do
    notify_parent({:open_brain_page, brain_id, page_id})
    {:noreply, socket}
  end

  def handle_event("create_brain", _, socket) do
    notify_parent(:create_brain)
    {:noreply, socket}
  end

  def handle_event("create_page", %{"brain-id" => brain_id}, socket) do
    notify_parent({:create_page_in_brain, brain_id})
    {:noreply, socket}
  end

  def handle_event("toggle_page", %{"page-id" => page_id}, socket) do
    expanded = socket.assigns.expanded_pages

    expanded =
      if MapSet.member?(expanded, page_id) do
        MapSet.delete(expanded, page_id)
      else
        MapSet.put(expanded, page_id)
      end

    {:noreply, assign(socket, :expanded_pages, expanded)}
  end

  def handle_event(
        "create_sub_page",
        %{"brain-id" => brain_id, "parent-page-id" => parent_page_id},
        socket
      ) do
    notify_parent({:create_page_in_brain, brain_id, parent_page_id})
    {:noreply, socket}
  end

  def handle_event("edit_brain", %{"brain-id" => brain_id}, socket) do
    brain = Enum.find(socket.assigns.brains, &(&1.id == brain_id))

    {:noreply,
     socket
     |> assign(:editing_brain_id, brain_id)
     |> assign(:editing_brain_title, (brain && brain.title) || "")}
  end

  def handle_event("save_brain_title", %{"title" => title} = params, socket) do
    brain_id = params["brain-id"] || socket.assigns.editing_brain_id
    title = String.trim(title)

    socket =
      if title != "" && brain_id do
        brain = Enum.find(socket.assigns.brains, &(&1.id == brain_id))

        if brain && title != brain.title do
          case Magus.Brain.update_brain(brain, %{title: title},
                 actor: socket.assigns.current_user
               ) do
            {:ok, _} -> load_brains(socket)
            {:error, _} -> socket
          end
        else
          socket
        end
      else
        socket
      end

    {:noreply, assign(socket, :editing_brain_id, nil)}
  end

  def handle_event("save_brain_title", _params, socket) do
    {:noreply, assign(socket, :editing_brain_id, nil)}
  end

  def handle_event("brain_title_keydown", %{"key" => "Escape"}, socket) do
    {:noreply, assign(socket, :editing_brain_id, nil)}
  end

  def handle_event("brain_title_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("delete_brain", %{"brain-id" => brain_id}, socket) do
    brain = Enum.find(socket.assigns.brains, &(&1.id == brain_id))

    if brain do
      Magus.Brain.destroy_brain!(brain, actor: socket.assigns.current_user)
      notify_parent({:brain_deleted, brain_id})
    end

    {:noreply, load_brains(socket)}
  end

  # -- Private helpers --

  defp load_brains(socket) do
    user = socket.assigns.current_user

    brains =
      case socket.assigns[:workspace_id] do
        nil -> Magus.Brain.list_brains!(actor: user)
        ws_id -> Magus.Brain.list_brains_for_workspace!(ws_id, actor: user)
      end

    filtered = filter_brains(brains, socket.assigns.search_query)

    socket
    |> assign(:brains, brains)
    |> assign(:filtered_brains, filtered)
  end

  defp load_pages_for_brain(socket, brain_id) do
    pages = Magus.Brain.list_pages!(brain_id, actor: socket.assigns.current_user)
    pages_by_brain = Map.put(socket.assigns.pages_by_brain, brain_id, pages)
    assign(socket, :pages_by_brain, pages_by_brain)
  end

  defp filter_brains(brains, "") do
    brains
  end

  defp filter_brains(brains, query) do
    query_down = String.downcase(query)

    Enum.filter(brains, fn brain ->
      String.contains?(String.downcase(brain.title), query_down) or
        (brain.description && String.contains?(String.downcase(brain.description), query_down))
    end)
  end

  defp brain_pages(brain, pages_by_brain) do
    Map.get(pages_by_brain, brain.id, [])
  end

  defp root_pages(pages) do
    pages
    |> Enum.filter(&is_nil(&1.parent_page_id))
    |> Enum.sort_by(& &1.position)
  end

  defp group_by_parent(pages) do
    Enum.group_by(pages, & &1.parent_page_id)
  end

  defp children_of(page, pages_by_parent) do
    pages_by_parent
    |> Map.get(page.id, [])
    |> Enum.sort_by(& &1.position)
  end

  defp has_children?(page, pages_by_parent) do
    Map.has_key?(pages_by_parent, page.id)
  end

  defp expand_ancestors(socket, page_id) do
    all_pages = socket.assigns.pages_by_brain |> Map.values() |> List.flatten()

    case Enum.find(all_pages, &(&1.id == page_id)) do
      nil ->
        socket

      page ->
        ancestor_ids =
          page
          |> Magus.Brain.Hierarchy.ancestor_pages(all_pages)
          |> Enum.map(& &1.id)

        expanded = Enum.reduce(ancestor_ids, socket.assigns.expanded_pages, &MapSet.put(&2, &1))
        assign(socket, :expanded_pages, expanded)
    end
  end

  attr :pages, :list, required: true
  attr :pages_by_parent, :map, required: true
  attr :brain_id, :string, required: true
  attr :active_page_id, :string
  attr :expanded_pages, MapSet, required: true
  attr :current_user_id, :string, required: true
  attr :target, :any, required: true
  attr :depth, :integer, default: 0

  def page_tree_nodes(assigns) do
    ~H"""
    <li :for={page <- @pages} class="w-full">
      <div class={[
        "group flex items-center gap-2 min-w-0",
        @active_page_id == page.id && "bg-primary/10 text-primary font-medium"
      ]}>
        <button
          :if={has_children?(page, @pages_by_parent)}
          type="button"
          class="flex-shrink-0"
          phx-click="toggle_page"
          phx-value-page-id={page.id}
          phx-target={@target}
        >
          <.icon
            name={
              if MapSet.member?(@expanded_pages, page.id),
                do: "lucide-chevron-down",
                else: "lucide-chevron-right"
            }
            class="w-3 h-3 text-base-content/40"
          />
        </button>
        <button
          type="button"
          class="flex items-center gap-2 flex-1 min-w-0"
          phx-click="open_page"
          phx-value-brain-id={@brain_id}
          phx-value-page-id={page.id}
          phx-target={@target}
        >
          <span :if={page.icon} class="text-sm shrink-0">{page.icon}</span>
          <.icon :if={!page.icon} name="lucide-file-text" class="w-3.5 h-3.5 shrink-0" />
          <span class="flex-1 truncate text-left">{page.title || "Untitled"}</span>
          <.viewer_badge page_id={page.id} current_user_id={@current_user_id} />
        </button>
      </div>

      <%= if has_children?(page, @pages_by_parent) and MapSet.member?(@expanded_pages, page.id) do %>
        <ul class="pl-4">
          <.page_tree_nodes
            pages={children_of(page, @pages_by_parent)}
            pages_by_parent={@pages_by_parent}
            brain_id={@brain_id}
            active_page_id={@active_page_id}
            expanded_pages={@expanded_pages}
            current_user_id={@current_user_id}
            target={@target}
            depth={@depth + 1}
          />
          <li>
            <button
              type="button"
              class="btn btn-ghost btn-xs gap-1 w-full justify-start py-1 text-base-content/40 hover:text-base-content"
              phx-click="create_sub_page"
              phx-value-brain-id={@brain_id}
              phx-value-parent-page-id={page.id}
              phx-target={@target}
            >
              <.icon name="lucide-plus" class="w-3 h-3" />
              <span class="text-xs">{gettext("New sub-page")}</span>
            </button>
          </li>
        </ul>
      <% end %>
    </li>
    """
  end

  attr :page_id, :string, required: true
  attr :current_user_id, :string, required: true

  defp viewer_badge(assigns) do
    viewers = Magus.Presence.list(:page, assigns.page_id)
    others = Enum.reject(viewers, &(&1.user_id == assigns.current_user_id))
    assigns = assign(assigns, :count, length(others))

    ~H"""
    <span
      :if={@count > 0}
      class="ml-1 inline-flex items-center justify-center w-4 h-4 rounded-full bg-primary/20 text-primary text-[9px] font-medium"
      title={"#{@count} other viewer(s)"}
    >
      {@count}
    </span>
    """
  end
end
