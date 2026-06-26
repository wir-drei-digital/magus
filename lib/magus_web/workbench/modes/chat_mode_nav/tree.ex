defmodule MagusWeb.Workbench.Modes.ChatModeNav.Tree do
  @moduledoc """
  LiveComponent that renders the folder/conversation tree for the
  workbench chat-mode nav. Owns expansion + edit state. Defers data
  loading to `MagusWeb.Workbench.Modes.ChatModeNav.Data` and rendering
  to the shared `MagusWeb.Workbench.Layout.ResourceTree` component.
  """
  use MagusWeb, :live_component

  alias MagusWeb.Workbench.Modes.ChatModeNav.Data

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:editing_folder_id, nil)
     |> assign(:favorites_collapsed?, false)}
  end

  @impl true
  def update(%{reload: _bump} = assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> reload_tree()

    {:ok, socket}
  end

  def update(assigns, socket) do
    user = assigns.current_user
    workspace_id = assigns.workspace_id
    nav_filter = assigns[:nav_filter] || :all

    expanded =
      socket.assigns[:expanded_folders] ||
        Magus.Chat.my_folder_states!(actor: user)
        |> Enum.filter(& &1.is_expanded)
        |> Map.new(&{to_string(&1.folder_id), true})

    tree =
      Data.load_tree(%{
        user: user,
        workspace_id: workspace_id,
        search_query: assigns[:search_query] || "",
        expanded_folders: expanded
      })

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:nav_filter, nav_filter)
     |> assign(:expanded_folders, expanded)
     |> assign(:tree, tree)}
  end

  @impl true
  def render(assigns) do
    sections =
      Data.to_sections(assigns.tree,
        nav_filter: assigns.nav_filter,
        editing_folder_id: assigns.editing_folder_id,
        favorites_collapsed?: assigns.favorites_collapsed?,
        tree_target: assigns.myself
      )

    assigns = assign(assigns, :sections, sections)

    ~H"""
    <div class="h-full min-h-0">
      <.live_component
        module={MagusWeb.Workbench.Layout.ResourceTree}
        id={"#{@id}-tree"}
        sections={@sections}
        expanded_folders={@expanded_folders}
        auto_expanded_ids={Map.get(@tree, :auto_expanded_ids, MapSet.new())}
        editing_id={@editing_folder_id}
      />
    </div>
    """
  end

  @impl true
  def handle_event("toggle_favorites_collapsed", _, socket) do
    {:noreply, assign(socket, :favorites_collapsed?, !socket.assigns.favorites_collapsed?)}
  end

  def handle_event("start_rename_folder", %{"folder-id" => id}, socket) do
    {:noreply, assign(socket, :editing_folder_id, id)}
  end

  def handle_event("cancel_rename_folder", _params, socket) do
    {:noreply, assign(socket, :editing_folder_id, nil)}
  end

  def handle_event("submit_rename_folder", %{"folder-id" => id, "name" => name}, socket) do
    folder = Magus.Chat.get_folder!(id, actor: socket.assigns.current_user)

    case Magus.Chat.update_folder(folder, %{name: name}, actor: socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply, socket |> assign(:editing_folder_id, nil) |> reload_tree()}

      {:error, _} ->
        send(self(), {:tree_message, {:flash, :error, "Could not rename folder"}})
        {:noreply, assign(socket, :editing_folder_id, nil)}
    end
  end

  def handle_event("toggle_folder", %{"folder-id" => folder_id}, socket) do
    current = Map.get(socket.assigns.expanded_folders, folder_id, false)
    new_state = !current

    Magus.Chat.upsert_folder_expanded!(
      %{folder_id: folder_id, is_expanded: new_state},
      actor: socket.assigns.current_user
    )

    expanded = Map.put(socket.assigns.expanded_folders, folder_id, new_state)
    {:noreply, assign(socket, :expanded_folders, expanded) |> reload_tree()}
  end

  def handle_event("delete_folder", %{"folder-id" => id}, socket) do
    folder = Magus.Chat.get_folder!(id, actor: socket.assigns.current_user)
    Magus.Chat.delete_folder!(folder, actor: socket.assigns.current_user)
    {:noreply, reload_tree(socket)}
  end

  def handle_event("toggle_favorite_conversation", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case Magus.Chat.get_conversation_favorite(id, actor: user) do
      {:ok, fav} ->
        Magus.Chat.destroy_conversation_favorite!(fav, actor: user)

      _ ->
        Magus.Chat.create_conversation_favorite!(%{conversation_id: id}, actor: user)
    end

    {:noreply, reload_tree(socket)}
  end

  def handle_event("create_conversation_in_folder", %{"folder-id" => folder_id}, socket) do
    user = socket.assigns.current_user

    attrs =
      if socket.assigns.workspace_id do
        %{folder_id: folder_id, workspace_id: socket.assigns.workspace_id}
      else
        %{folder_id: folder_id}
      end

    case Magus.Chat.create_conversation(attrs, actor: user) do
      {:ok, conv} ->
        conv = inherit_folder_workspace_share(conv, folder_id, user)
        send(self(), {:tree_message, {:open_conversation, conv.id, conv.title || "New chat"}})
        {:noreply, reload_tree(socket)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_conversation", %{"id" => id}, socket) do
    conv = Magus.Chat.get_conversation!(id, actor: socket.assigns.current_user)
    Magus.Chat.soft_delete_conversation!(conv, actor: socket.assigns.current_user)
    {:noreply, reload_tree(socket)}
  end

  def handle_event("share_conversation", %{"id" => id}, socket) do
    conv = Magus.Chat.get_conversation!(id, actor: socket.assigns.current_user)
    Magus.Chat.share_conversation_to_team!(conv, actor: socket.assigns.current_user)
    {:noreply, reload_tree(socket)}
  end

  def handle_event("unshare_conversation", %{"id" => id}, socket) do
    conv = Magus.Chat.get_conversation!(id, actor: socket.assigns.current_user)
    Magus.Chat.unshare_conversation_from_team!(conv, actor: socket.assigns.current_user)
    {:noreply, reload_tree(socket)}
  end

  def handle_event("share_folder", %{"folder-id" => id}, socket) do
    folder = Magus.Chat.get_folder!(id, actor: socket.assigns.current_user)
    Magus.Chat.share_folder_to_team!(folder, actor: socket.assigns.current_user)
    {:noreply, reload_tree(socket)}
  end

  def handle_event("unshare_folder", %{"folder-id" => id}, socket) do
    folder = Magus.Chat.get_folder!(id, actor: socket.assigns.current_user)
    Magus.Chat.unshare_folder_from_team!(folder, actor: socket.assigns.current_user)
    {:noreply, reload_tree(socket)}
  end

  def handle_event("move_conversation", params, socket) do
    user = socket.assigns.current_user

    case params do
      %{"conversation_id" => conv_id, "folder_id" => folder_id, "section" => section} ->
        case Magus.Chat.get_conversation(conv_id, actor: user) do
          {:ok, conv} ->
            conv = Ash.load!(conv, :is_shared_to_workspace, actor: user)

            if conversation_section(conv) == section do
              target_folder_id = if folder_id == "", do: nil, else: folder_id

              Magus.Chat.move_conversation_to_folder!(
                conv,
                %{folder_id: target_folder_id},
                actor: user
              )

              {:noreply, reload_tree(socket)}
            else
              {:noreply, socket}
            end

          _ ->
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("move_folder", params, socket) do
    user = socket.assigns.current_user

    case params do
      %{"folder_id" => folder_id, "parent_id" => parent_id, "section" => section} ->
        case Magus.Chat.get_folder(folder_id, actor: user) do
          {:ok, folder} ->
            folder = Ash.load!(folder, :is_shared_to_workspace, actor: user)

            if folder_section(folder) == section do
              target_parent_id = if parent_id == "", do: nil, else: parent_id
              Magus.Chat.move_folder!(folder, %{parent_id: target_parent_id}, actor: user)
              {:noreply, reload_tree(socket)}
            else
              {:noreply, socket}
            end

          _ ->
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  defp conversation_section(conv) do
    cond do
      is_nil(conv.workspace_id) -> "personal"
      Map.get(conv, :is_shared_to_workspace, false) -> "shared"
      true -> "personal"
    end
  end

  defp folder_section(folder) do
    cond do
      is_nil(folder.workspace_id) -> "personal"
      Map.get(folder, :is_shared_to_workspace, false) -> "shared"
      true -> "personal"
    end
  end

  # When a chat is created inside a folder that is shared with the workspace,
  # the conversation must inherit that share — otherwise it stays personal and
  # never appears in the shared section of the nav (where the user is browsing).
  defp inherit_folder_workspace_share(conv, folder_id, user) do
    with id when is_binary(id) <- folder_id,
         {:ok, folder} <- Magus.Chat.get_folder(folder_id, actor: user),
         folder = Ash.load!(folder, :is_shared_to_workspace, actor: user),
         true <- Map.get(folder, :is_shared_to_workspace, false) do
      case Magus.Chat.share_conversation_to_team(conv, actor: user) do
        {:ok, shared} -> shared
        _ -> conv
      end
    else
      _ -> conv
    end
  end

  defp reload_tree(socket) do
    tree =
      Data.load_tree(%{
        user: socket.assigns.current_user,
        workspace_id: socket.assigns.workspace_id,
        search_query: socket.assigns[:search_query] || "",
        expanded_folders: socket.assigns.expanded_folders
      })

    assign(socket, :tree, tree)
  end
end
