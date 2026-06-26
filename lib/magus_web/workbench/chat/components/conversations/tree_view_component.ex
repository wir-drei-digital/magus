defmodule MagusWeb.ChatLive.Components.Conversations.TreeViewComponent do
  @moduledoc """
  LiveComponent for rendering the folder and conversation tree.

  Handles:
  - Folder expansion/collapse
  - Folder editing and deletion
  - Conversation deletion
  - Creating conversations in folders

  Uses `phx-target={@myself}` for all events.
  Notifies parent via `notify_parent/1` for navigation and state changes.
  """
  use MagusWeb, :live_component
  use MagusWeb.Live.Shared.ComponentUtils

  import MagusWeb.ChatLive.Helpers

  def render(assigns) do
    # Get IDs of favorite conversations to filter them from unfiled
    favorite_ids = Enum.map(assigns.favorite_conversations, & &1.id) |> MapSet.new()

    # Filter unfiled conversations: exclude favorites that are not in a folder
    filtered_unfiled =
      Enum.reject(assigns.unfiled_conversations, fn conv ->
        MapSet.member?(favorite_ids, conv.id)
      end)

    in_workspace = not is_nil(assigns[:current_workspace])

    active_thread_id =
      cond do
        assigns[:active_thread] -> assigns.active_thread.id
        assigns[:active_thread_id] -> assigns.active_thread_id
        true -> nil
      end

    assigns =
      assigns
      |> assign(:filtered_unfiled, filtered_unfiled)
      |> assign_new(:team_conversations, fn -> [] end)
      |> assign_new(:current_workspace, fn -> nil end)
      |> assign(:in_workspace, in_workspace)
      |> assign_new(:threads_by_conversation, fn -> %{} end)
      |> assign(:active_thread_id, active_thread_id)

    ~H"""
    <div class="flex flex-col flex-1 overflow-hidden">
      <%!-- Chats --%>
      <div
        id={"tree-root-drop-#{@id}"}
        class="flex-1 overflow-y-auto overflow-x-hidden"
        phx-hook="DroppableFolder"
        data-folder-id=""
      >
        <%!-- Favorites Section (personal mode only) --%>
        <ul
          :if={!@in_workspace && length(@favorite_conversations) > 0}
          class="menu menu-md w-full pt-4"
        >
          <li class="w-full">
            <div class="group flex items-center w-full">
              <button
                type="button"
                class="flex items-center gap-2 flex-1 min-w-0 w-full cursor-pointer rounded-lg"
                phx-click="toggle_favorites_collapsed"
                phx-target={@myself}
              >
                <.icon name="lucide-star" class="w-4 h-4 shrink-0" />
                <span class="flex-1 truncate text-left">{gettext("Favorites")}</span>
                <span class="text-xs opacity-50">({length(@favorite_conversations)})</span>
              </button>
            </div>
            <ul :if={!@favorites_collapsed} class="ml-4">
              <.conversation_item
                :for={conv <- @favorite_conversations}
                conversation={conv}
                current_conversation_id={@current_conversation_id}
                myself={@myself}
                threads={Map.get(@threads_by_conversation, conv.id, [])}
                active_thread_id={@active_thread_id}
              />
            </ul>
          </li>
        </ul>

        <%!-- Workspace mode: Team and Personal sections --%>
        <%= if @in_workspace do %>
          <%!-- Team Conversations Section --%>
          <ul class="menu menu-md w-full pt-4">
            <li class="menu-title">
              <span class="text-xs text-base-content/50 uppercase tracking-wider flex items-center gap-1">
                {gettext("Team")}
              </span>
            </li>
            <.conversation_item
              :for={conv <- sorted_conversations(@team_conversations)}
              conversation={conv}
              current_conversation_id={@current_conversation_id}
              myself={@myself}
              threads={Map.get(@threads_by_conversation, conv.id, [])}
              active_thread_id={@active_thread_id}
            />
            <li :if={@team_conversations == []}>
              <span class="text-xs text-base-content/40 italic">
                {gettext("No shared conversations")}
              </span>
            </li>
          </ul>

          <%!-- Personal Conversations Section (within workspace) --%>
          <ul class="menu menu-md w-full">
            <li class="menu-title mt-2">
              <span class="text-xs text-base-content/50 uppercase tracking-wider flex items-center gap-1">
                {gettext("Personal")}
              </span>
            </li>
            <.conversation_item
              :for={conv <- sorted_conversations(@filtered_unfiled)}
              conversation={conv}
              current_conversation_id={@current_conversation_id}
              myself={@myself}
              threads={Map.get(@threads_by_conversation, conv.id, [])}
              active_thread_id={@active_thread_id}
            />
            <li :if={@filtered_unfiled == []}>
              <span class="text-xs text-base-content/40 italic">
                {gettext("No personal conversations")}
              </span>
            </li>
          </ul>
        <% else %>
          <%!-- Personal mode: standard layout --%>
          <ul class="menu menu-md w-full">
            <%!-- Root folders (sorted by name) --%>
            <.folder_item
              :for={folder <- sorted_folders(root_folders(@folders))}
              folder={folder}
              expanded_folders={@expanded_folders}
              current_conversation_id={@current_conversation_id}
              myself={@myself}
            />
          </ul>

          <%!-- Unfiled conversations grouped by date --%>
          <ul id="unfiled-conversations" class="menu menu-md w-full min-h-[20px]">
            <.date_group
              :for={{label, convs} <- group_conversations_by_date(@filtered_unfiled)}
              label={label}
              conversations={convs}
              current_conversation_id={@current_conversation_id}
              myself={@myself}
              threads_by_conversation={@threads_by_conversation}
              active_thread_id={@active_thread_id}
            />

            <%!-- View History Link --%>
            <li :if={length(@filtered_unfiled) > 0} class="mt-3">
              <.link
                navigate={~p"/history"}
                class="flex items-center gap-2 text-sm text-base-content/60 hover:text-primary"
              >
                <.icon name="lucide-more-horizontal" class="w-4 h-4" />
                <span>{gettext("Show History")}</span>
              </.link>
            </li>
          </ul>
        <% end %>
      </div>
    </div>
    """
  end

  attr(:folder, :map, required: true)
  attr(:expanded_folders, :map, required: true)
  attr(:current_conversation_id, :string)
  attr(:myself, :any, required: true)

  defp folder_item(assigns) do
    folder_id = to_string(assigns.folder.id)
    expanded = Map.get(assigns.expanded_folders, folder_id, false)
    has_content = not folder_empty?(assigns.folder)
    assigns = assign(assigns, expanded: expanded, has_content: has_content)

    ~H"""
    <li
      id={"folder-tree-#{@folder.id}"}
      phx-hook="FolderDropZone"
      data-folder-id={@folder.id}
      class="w-full"
    >
      <div
        class="group flex items-center w-full"
        id={"folder-drag-#{@folder.id}"}
        draggable="true"
        data-folder-id={@folder.id}
        data-folder-header
        phx-hook="DraggableFolder"
      >
        <button
          type="button"
          class="flex items-center gap-2 flex-1 min-w-0 w-full cursor-pointer  rounded-lg "
          phx-click="toggle_folder"
          phx-value-folder-id={@folder.id}
          phx-target={@myself}
        >
          <.icon
            name={if @expanded, do: "lucide-folder-open", else: "lucide-folder"}
            class="w-4 h-4 shrink-0"
          />
          <span class="flex-1 truncate text-left">{@folder.name}</span>
        </button>
        <div class="opacity-0 group-hover:opacity-100 flex items-center gap-0.5 shrink-0">
          <button
            type="button"
            class="btn btn-ghost btn-xs btn-square"
            phx-click="edit_folder"
            phx-value-folder-id={@folder.id}
            phx-target={@myself}
          >
            <.icon name="lucide-pencil" class="w-4 h-4" />
          </button>
          <button
            type="button"
            class="btn btn-ghost btn-xs btn-square text-error"
            phx-click="delete_folder"
            phx-value-folder-id={@folder.id}
            phx-target={@myself}
          >
            <.icon name="lucide-trash-2" class="w-4 h-4" />
          </button>
        </div>
      </div>
      <ul :if={@expanded} class="ml-4">
        <%!-- Child folders (sorted by name) --%>
        <.folder_item
          :for={child <- sorted_folders(safe_list(@folder.children))}
          folder={child}
          expanded_folders={@expanded_folders}
          current_conversation_id={@current_conversation_id}
          myself={@myself}
        />

        <%!-- Conversations in this folder (sorted by updated_at desc) --%>
        <.conversation_item
          :for={conv <- sorted_conversations(safe_list(@folder.conversations))}
          conversation={conv}
          current_conversation_id={@current_conversation_id}
          myself={@myself}
        />

        <%!-- Add new conversation button --%>
        <li>
          <button
            type="button"
            class="btn btn-ghost btn-sm gap-1 w-full justify-start py-2 text-base-content/60 hover:text-base-content hover:bg-primary/80"
            phx-click="create_conversation_in_folder"
            phx-value-folder-id={@folder.id}
            phx-target={@myself}
          >
            <.icon name="lucide-plus" class="w-4 h-4" />
            <span class="text-xs">{gettext("New Chat")}</span>
          </button>
        </li>
      </ul>
    </li>
    """
  end

  attr(:label, :string, required: true)
  attr(:conversations, :list, required: true)
  attr(:current_conversation_id, :string)
  attr(:myself, :any, required: true)
  attr(:threads_by_conversation, :map, default: %{})
  attr(:active_thread_id, :string, default: nil)

  defp date_group(assigns) do
    ~H"""
    <li class="menu-title mt-2">
      <span class="text-xs text-base-content/50 uppercase tracking-wider">{@label}</span>
    </li>
    <.conversation_item
      :for={conv <- @conversations}
      conversation={conv}
      current_conversation_id={@current_conversation_id}
      myself={@myself}
      threads={Map.get(@threads_by_conversation, conv.id, [])}
      active_thread_id={@active_thread_id}
    />
    """
  end

  attr(:conversation, :map, required: true)
  attr(:current_conversation_id, :string)
  attr(:myself, :any, required: true)
  attr(:threads, :list, default: [])
  attr(:active_thread_id, :string, default: nil)

  defp conversation_item(assigns) do
    is_active = assigns.current_conversation_id == assigns.conversation.id
    is_workspace = not is_nil(assigns.conversation.workspace_id)

    is_shared =
      is_workspace and
        Map.get(assigns.conversation, :is_shared_to_workspace, false) == true

    assigns =
      assigns
      |> assign(:is_active, is_active)
      |> assign(:is_workspace, is_workspace)
      |> assign(:is_shared, is_shared)

    ~H"""
    <li
      draggable="true"
      data-conversation-id={@conversation.id}
      phx-hook="DraggableConversation"
      id={"conv-item-#{@conversation.id}"}
    >
      <div class={[
        "group flex items-center gap-2 rounded-lg min-w-0",
        @is_active && "bg-primary/10 text-primary font-medium"
      ]}>
        <.link
          navigate={~p"/chat/#{@conversation.id}"}
          class="flex items-center gap-2 flex-1 min-w-0"
          title={build_conversation_title_string(@conversation.title)}
        >
          <.icon
            :if={@conversation.is_multiplayer}
            name="lucide-users"
            class={["w-4 h-4 shrink-0", if(@is_active, do: "text-primary", else: "text-primary")]}
          />
          <.icon
            :if={!@conversation.is_multiplayer}
            name="lucide-messages-square"
            class={["w-4 h-4 shrink-0", @is_active && "text-primary"]}
          />
          <span class="flex-1 truncate">{build_conversation_title_string(@conversation.title)}</span>
          <span :if={@is_shared} title={gettext("Shared with team")}>
            <.icon name="lucide-building-2" class="w-3 h-3 shrink-0 text-base-content/40" />
          </span>
        </.link>
        <div class="opacity-0 group-hover:opacity-100 flex items-center shrink-0">
          <button
            :if={@is_workspace && !@is_shared}
            type="button"
            class="btn btn-ghost btn-xs btn-square"
            phx-click="share_to_team"
            phx-value-id={@conversation.id}
            phx-target={@myself}
            title={gettext("Share with team")}
          >
            <.icon name="lucide-share-2" class="w-4 h-4" />
          </button>
          <button
            :if={@is_shared}
            type="button"
            class="btn btn-ghost btn-xs btn-square"
            phx-click="unshare_from_team"
            phx-value-id={@conversation.id}
            phx-target={@myself}
            title={gettext("Make private")}
          >
            <.icon name="lucide-lock" class="w-4 h-4" />
          </button>
          <button
            type="button"
            class="btn btn-ghost btn-xs btn-square text-error"
            phx-click="delete_conversation"
            phx-value-id={@conversation.id}
            phx-target={@myself}
          >
            <.icon name="lucide-trash-2" class="w-4 h-4" />
          </button>
        </div>
      </div>
    </li>
    <li
      :for={thread <- @threads}
      class="!block ml-4 border-l-2 border-primary/20 pl-1 w-[calc(100%-1rem)] group/thread relative"
    >
      <button
        type="button"
        phx-click="open_thread_from_sidebar"
        phx-value-thread-id={thread.id}
        phx-value-parent-id={thread.parent_conversation_id}
        class={[
          "flex items-center gap-1.5 w-full min-w-0 px-2 py-1 rounded text-xs",
          @active_thread_id == thread.id && "bg-primary/10 text-primary",
          @active_thread_id != thread.id &&
            "text-base-content/60 hover:text-base-content hover:bg-base-200"
        ]}
      >
        <.icon name="lucide-corner-down-right" class="w-3 h-3 shrink-0 text-primary/60" />
        <span class="truncate">{thread.title || gettext("Thread")}</span>
      </button>
      <button
        type="button"
        class="opacity-0 group-hover/thread:opacity-100 absolute right-0 top-0 bottom-0 flex items-center px-1 text-error hover:text-error/80"
        phx-click="delete_thread"
        phx-value-id={thread.id}
        phx-target={@myself}
      >
        <.icon name="lucide-trash-2" class="w-3 h-3" />
      </button>
    </li>
    """
  end

  def mount(socket) do
    {:ok, socket}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  def handle_event("toggle_favorites_collapsed", _, socket) do
    # Notify parent (ChatLive) to handle the toggle
    send(self(), "toggle_favorites_collapsed")
    {:noreply, socket}
  end

  def handle_event("toggle_folder", %{"folder-id" => folder_id}, socket) do
    current_state = Map.get(socket.assigns.expanded_folders, folder_id, false)
    new_state = !current_state

    # Persist to database
    Magus.Chat.upsert_folder_expanded!(
      %{folder_id: folder_id, is_expanded: new_state},
      actor: socket.assigns.current_user
    )

    # Notify parent to update expanded_folders map
    notify_parent({:folder_expanded_changed, folder_id, new_state})

    {:noreply, socket}
  end

  def handle_event("edit_folder", %{"folder-id" => folder_id}, socket) do
    notify_parent({:edit_folder, folder_id})
    {:noreply, socket}
  end

  def handle_event("delete_folder", %{"folder-id" => folder_id}, socket) do
    Magus.Chat.delete_folder!(folder_id, actor: socket.assigns.current_user)
    {:noreply, socket}
  end

  def handle_event("delete_conversation", %{"id" => id}, socket) do
    conversation = Magus.Chat.get_conversation!(id, actor: socket.assigns.current_user)
    Magus.Chat.soft_delete_conversation!(conversation, actor: socket.assigns.current_user)
    notify_parent(:conversations_changed)
    {:noreply, socket}
  end

  def handle_event("delete_thread", %{"id" => id}, socket) do
    thread = Magus.Chat.get_conversation!(id, actor: socket.assigns.current_user)
    Magus.Chat.soft_delete_conversation!(thread, actor: socket.assigns.current_user)
    notify_parent({:thread_deleted, id})
    {:noreply, socket}
  end

  def handle_event("share_to_team", %{"id" => id}, socket) do
    conversation = Magus.Chat.get_conversation!(id, actor: socket.assigns.current_user)
    Magus.Chat.share_conversation_to_team!(conversation, actor: socket.assigns.current_user)
    notify_parent(:conversations_changed)
    {:noreply, socket}
  end

  def handle_event("unshare_from_team", %{"id" => id}, socket) do
    conversation = Magus.Chat.get_conversation!(id, actor: socket.assigns.current_user)
    Magus.Chat.unshare_conversation_from_team!(conversation, actor: socket.assigns.current_user)
    notify_parent(:conversations_changed)
    {:noreply, socket}
  end

  def handle_event("create_conversation_in_folder", %{"folder-id" => folder_id}, socket) do
    conversation =
      Magus.Chat.create_conversation!(
        %{folder_id: folder_id},
        actor: socket.assigns.current_user
      )

    notify_parent({:navigate, ~p"/chat/#{conversation.id}"})
    {:noreply, socket}
  end

  # Helper to get root folders (those without a parent)
  defp root_folders(folders) do
    Enum.filter(folders, fn f -> is_nil(f.parent_id) end)
  end

  # Sort folders alphabetically by name (case-insensitive)
  defp sorted_folders(folders) do
    Enum.sort_by(folders, fn f -> String.downcase(f.name) end)
  end

  # Sort conversations by last message date descending (most recent first)
  defp sorted_conversations(conversations) do
    Enum.sort_by(conversations, &conversation_sort_date/1, {:desc, DateTime})
  end

  defp conversation_sort_date(%{last_message_at: %DateTime{} = dt}), do: dt
  defp conversation_sort_date(%{updated_at: dt}), do: dt

  # Safely convert a potentially nil or NotLoaded value to a list
  defp safe_list(nil), do: []
  defp safe_list(%Ash.NotLoaded{}), do: []
  defp safe_list(list) when is_list(list), do: list

  # Check if folder has no children and no conversations
  defp folder_empty?(folder) do
    safe_list(folder.children) == [] and safe_list(folder.conversations) == []
  end
end
