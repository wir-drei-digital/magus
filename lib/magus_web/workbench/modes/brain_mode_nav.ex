defmodule MagusWeb.Workbench.Modes.BrainModeNav do
  @moduledoc """
  Brain mode nav. Renders brains and (lazy-loaded) pages via the
  shared `ResourceTree` component.
  """
  use MagusWeb, :live_component

  alias MagusWeb.Workbench.Modes.BrainModeNav.Data
  alias MagusWeb.Workbench.WorkspaceShare

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:expanded_brain_ids, MapSet.new())
     |> assign(:new_brain?, false)}
  end

  @impl true
  def update(%{begin_new_brain: _bump}, socket) do
    {:ok, assign(socket, :new_brain?, true)}
  end

  def update(%{expand_brain: brain_id}, socket) do
    expanded = MapSet.put(socket.assigns.expanded_brain_ids, brain_id)
    socket = assign(socket, :expanded_brain_ids, expanded)
    sections = build_sections(socket)
    {:ok, assign(socket, :sections, sections)}
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)
    sections = build_sections(socket)
    {:ok, assign(socket, :sections, sections)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full overflow-hidden">
      <form
        :if={@new_brain?}
        phx-submit="create_brain"
        phx-target={@myself}
        class="px-3 py-2 border-b border-wb-border"
      >
        <input
          type="text"
          name="title"
          autofocus
          placeholder="Brain name"
          phx-keydown="cancel_new_brain"
          phx-key="Escape"
          phx-target={@myself}
          class="w-full px-2 py-1.5 text-sm rounded-md bg-wb-surface-2 border border-wb-accent text-wb-text placeholder:text-wb-text-dim focus:outline-none"
        />
      </form>

      <div class="flex-1 min-h-0 overflow-hidden">
        <.live_component
          module={MagusWeb.Workbench.Layout.ResourceTree}
          id={"#{@id}-tree"}
          sections={@sections}
          expanded_folders={expanded_brain_map(@expanded_brain_ids)}
          auto_expanded_ids={MapSet.new()}
          editing_id={nil}
        />
      </div>

      <div class="border-t border-wb-border px-3 py-2">
        <.link
          navigate={~p"/brain/trash"}
          class="flex items-center gap-2 px-2 py-1.5 text-xs rounded-md text-wb-text-dim hover:text-wb-text hover:bg-wb-hover transition-colors"
        >
          <.icon name="lucide-trash-2" class="w-3.5 h-3.5" />
          <span>Show trash</span>
        </.link>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("toggle_folder", %{"folder-id" => id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded_brain_ids, id) do
        MapSet.delete(socket.assigns.expanded_brain_ids, id)
      else
        MapSet.put(socket.assigns.expanded_brain_ids, id)
      end

    socket = assign(socket, :expanded_brain_ids, expanded)
    sections = build_sections(socket)

    {:noreply, assign(socket, :sections, sections)}
  end

  def handle_event("cancel_new_brain", _params, socket) do
    {:noreply, assign(socket, :new_brain?, false)}
  end

  def handle_event("create_brain", %{"title" => ""}, socket) do
    {:noreply, assign(socket, :new_brain?, false)}
  end

  def handle_event("create_brain", %{"title" => title}, socket) do
    user = socket.assigns.current_user

    attrs =
      if socket.assigns.workspace_id do
        %{title: title, workspace_id: socket.assigns.workspace_id}
      else
        %{title: title}
      end

    case Magus.Brain.create_brain(attrs, actor: user) do
      {:ok, _} ->
        socket = assign(socket, :new_brain?, false)
        sections = build_sections(socket)
        {:noreply, assign(socket, :sections, sections)}

      {:error, _} ->
        {:noreply, assign(socket, :new_brain?, false)}
    end
  end

  def handle_event("edit_brain", %{"brain-id" => brain_id}, socket) do
    send(self(), {:open_brain_settings, brain_id})
    {:noreply, socket}
  end

  def handle_event("share_brain", %{"brain-id" => brain_id}, socket) do
    {:noreply, toggle_share(socket, brain_id, :share)}
  end

  def handle_event("unshare_brain", %{"brain-id" => brain_id}, socket) do
    {:noreply, toggle_share(socket, brain_id, :unshare)}
  end

  def handle_event("trash_page", %{"page-id" => page_id}, socket) do
    user = socket.assigns.current_user

    case Magus.Brain.get_page(page_id, actor: user) do
      {:ok, page} ->
        _ = Magus.Brain.soft_delete_page(page, actor: user)
        sections = build_sections(socket)
        {:noreply, assign(socket, :sections, sections)}

      _ ->
        {:noreply, socket}
    end
  end

  defp toggle_share(socket, brain_id, action) do
    user = socket.assigns.current_user

    with {:ok, brain} <- Magus.Brain.get_brain(brain_id, actor: user),
         {:ok, _} <- do_share(action, brain, user) do
      Magus.Endpoint.broadcast(
        Magus.Brain.Topics.brain(brain.id),
        "brain.visibility_changed",
        %{brain_id: brain.id}
      )

      assign(socket, :sections, build_sections(socket))
    else
      _ -> socket
    end
  end

  defp do_share(:share, brain, user), do: WorkspaceShare.share(:brain, brain, user)
  defp do_share(:unshare, brain, user), do: WorkspaceShare.unshare(:brain, brain, user)

  defp expanded_brain_map(expanded_ids) do
    Enum.into(expanded_ids, %{}, fn id -> {to_string(id), true} end)
  end

  defp build_sections(socket) do
    Data.load_sections(%{
      user: socket.assigns.current_user,
      workspace_id: socket.assigns.workspace_id,
      search_query: socket.assigns[:search_query] || "",
      nav_filter: socket.assigns[:nav_filter] || :all,
      expanded_brain_ids: socket.assigns.expanded_brain_ids,
      tree_target: socket.assigns.myself
    })
  end
end
