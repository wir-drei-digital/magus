defmodule MagusWeb.Workbench.Modes.ChatModeNav do
  @moduledoc """
  Chat mode nav pane.

  Thin shell that renders a toolbar (new folder / new chat) plus the
  `ChatModeNav.Tree` live component which owns all the rendering of
  conversations, folders, and threads.

  `nav_filter` is only meaningful in workspace mode (:all | :shared | :personal)
  and is forwarded to the Tree. `search_query` is also forwarded.
  """
  use MagusWeb, :live_component

  import MagusWeb.Workbench.Components.InlineEditActions

  @impl true
  def update(%{begin_new_folder: _bump} = assigns, socket) do
    {:ok,
     socket
     |> assign(Map.drop(assigns, [:begin_new_folder]))
     |> assign(:new_folder?, true)}
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:new_folder?, fn -> false end)}
  end

  @impl true
  def handle_event("begin_new_folder", _params, socket) do
    {:noreply, assign(socket, :new_folder?, true)}
  end

  def handle_event("cancel_new_folder", _params, socket) do
    {:noreply, assign(socket, :new_folder?, false)}
  end

  def handle_event("create_folder_root", %{"name" => name}, socket) do
    user = socket.assigns.current_user

    attrs =
      if socket.assigns.workspace_id do
        %{name: name, workspace_id: socket.assigns.workspace_id, kind: :conversations}
      else
        %{name: name, kind: :conversations}
      end

    case Magus.Chat.create_folder(attrs, actor: user) do
      {:ok, _} ->
        send_update(MagusWeb.Workbench.Modes.ChatModeNav.Tree,
          id: "#{socket.assigns.id}-tree",
          reload: System.unique_integer()
        )

        {:noreply, assign(socket, :new_folder?, false)}

      {:error, _} ->
        {:noreply, assign(socket, :new_folder?, false)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full overflow-hidden">
      <form
        :if={@new_folder?}
        phx-submit="create_folder_root"
        phx-target={@myself}
        class="px-3 py-2 border-b border-wb-border flex items-center gap-1"
      >
        <input
          type="text"
          name="name"
          autofocus
          placeholder={gettext("Folder name")}
          phx-keydown="cancel_new_folder"
          phx-key="Escape"
          phx-target={@myself}
          class="flex-1 min-w-0 px-2 py-1.5 text-sm rounded-md bg-wb-surface-2 border border-wb-accent text-wb-text placeholder:text-wb-text-dim focus:outline-none"
        />
        <.inline_edit_actions
          cancel_event="cancel_new_folder"
          target={@myself}
          save_label={gettext("Create folder")}
        />
      </form>

      <div class="flex-1 min-h-0 overflow-hidden">
        <.live_component
          module={MagusWeb.Workbench.Modes.ChatModeNav.Tree}
          id={"#{@id}-tree"}
          current_user={@current_user}
          workspace_id={@workspace_id}
          search_query={@search_query}
          nav_filter={@nav_filter}
        />
      </div>

      <div class="border-t border-wb-border px-3 py-2">
        <.link
          navigate={~p"/history"}
          class="flex items-center gap-2 px-2 py-1.5 text-xs rounded-md text-wb-text-dim hover:text-wb-text hover:bg-wb-hover transition-colors"
        >
          <.icon name="lucide-history" class="w-3.5 h-3.5" />
          <span>Show history</span>
        </.link>
      </div>
    </div>
    """
  end
end
