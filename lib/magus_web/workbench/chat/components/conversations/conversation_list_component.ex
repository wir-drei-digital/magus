defmodule MagusWeb.ChatLive.Components.Conversations.ConversationListComponent do
  use MagusWeb, :live_component

  alias MagusWeb.ChatLive.Components.WorkspaceSelectorComponent

  def render(assigns) do
    # Default hide_header to false if not provided
    assigns =
      assigns
      |> assign_new(:hide_header, fn -> false end)
      |> assign_new(:workspaces, fn -> [] end)
      |> assign_new(:can_create_workspace, fn -> false end)

    ~H"""
    <div class="flex flex-col h-full w-full">
      <%!-- Header with controls --%>
      <div class="p-4">
        <div :if={!@hide_header} class="flex items-center justify-between mb-3">
          <span class="text-lg font-medium">{gettext("Conversations")}</span>
          <button
            type="button"
            class="btn btn-ghost btn-xs btn-square"
            phx-click="toggle_sidebar_collapse"
            title={gettext("Collapse sidebar")}
          >
            <.icon name="lucide-chevrons-left" class="w-5 h-5" />
          </button>
        </div>

        <%!-- Action buttons --%>
        <div class="flex gap-2">
          <.link navigate={~p"/chat"} class="btn btn-primary btn-sm flex-1">
            <.icon name="lucide-plus" class="w-4 h-4" />
            <span>{gettext("New Chat")}</span>
          </.link>
          <button
            type="button"
            class="btn btn-outline btn-sm"
            phx-click="new_folder"
            phx-target={@myself}
            title={gettext("New Folder")}
          >
            <.icon name="lucide-folder-plus" class="w-5 h-5" />
          </button>
        </div>
      </div>

      <%!-- Workspace Selector --%>
      <div
        :if={@workspaces != [] or @can_create_workspace}
        class="px-1 pt-3 pb-1"
      >
        <.live_component
          module={WorkspaceSelectorComponent}
          id="workspace-selector"
          workspaces={@workspaces}
          current_workspace={@current_workspace}
          can_create_workspace={@can_create_workspace}
        />
      </div>

      <%!-- Tree View --%>
      <.live_component
        module={MagusWeb.ChatLive.Components.Conversations.TreeViewComponent}
        id={"tree-view-#{@id}"}
        folders={@folders}
        unfiled_conversations={@unfiled_conversations}
        team_conversations={@team_conversations}
        expanded_folders={@expanded_folders}
        current_conversation_id={@current_conversation_id}
        current_user={@current_user}
        favorite_conversations={@favorite_conversations}
        favorites_collapsed={@favorites_collapsed}
        current_workspace={@current_workspace}
        threads_by_conversation={assigns[:threads_by_conversation] || %{}}
        active_thread={assigns[:active_thread]}
      />

      <%!-- New Folder Modal --%>
      <dialog class={["modal", @show_folder_modal && "modal-open"]}>
        <div class="modal-box">
          <h3 class="font-bold text-lg mb-4">
            {if @editing_folder_id, do: gettext("Edit Folder"), else: gettext("New Folder")}
          </h3>
          <.form
            for={@folder_form}
            phx-submit="save_folder"
            phx-target={@myself}
          >
            <.input
              field={@folder_form[:name]}
              type="text"
              label={gettext("Folder Name")}
              placeholder={gettext("My Folder")}
              required
            />
            <.input
              field={@folder_form[:parent_id]}
              type="select"
              label={gettext("Parent Folder (optional)")}
              prompt={gettext("No parent (root level)")}
              options={folder_options(@folders, @editing_folder_id)}
            />
            <div class="modal-action">
              <button
                type="button"
                class="btn btn-ghost"
                phx-click="cancel_folder_modal"
                phx-target={@myself}
              >
                {gettext("Cancel")}
              </button>
              <button type="submit" class="btn btn-primary">
                {if @editing_folder_id, do: gettext("Update"), else: gettext("Create")}
              </button>
            </div>
          </.form>
        </div>
        <form method="dialog" class="modal-backdrop">
          <button phx-click="cancel_folder_modal" phx-target={@myself}>close</button>
        </form>
      </dialog>
    </div>
    """
  end

  def mount(socket) do
    {:ok,
     socket
     |> assign(:show_folder_modal, false)
     |> assign(:editing_folder_id, nil)
     |> assign_folder_form(%{})}
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # If editing a folder, load it and populate the form
    socket =
      if assigns[:editing_folder_id] && assigns[:show_folder_modal] do
        folder =
          Magus.Chat.get_folder!(assigns.editing_folder_id,
            actor: socket.assigns.current_user
          )

        assign_folder_form(socket, %{"name" => folder.name, "parent_id" => folder.parent_id})
      else
        socket
      end

    {:ok, socket}
  end

  def handle_event("new_folder", _, socket) do
    {:noreply,
     socket
     |> assign(:show_folder_modal, true)
     |> assign(:editing_folder_id, nil)
     |> assign_folder_form(%{})}
  end

  def handle_event("cancel_folder_modal", _, socket) do
    {:noreply,
     socket
     |> assign(:show_folder_modal, false)
     |> assign(:editing_folder_id, nil)}
  end

  def handle_event("save_folder", %{"folder" => params}, socket) do
    params = Map.reject(params, fn {_k, v} -> v == "" end)

    if socket.assigns.editing_folder_id do
      folder =
        Magus.Chat.get_folder!(socket.assigns.editing_folder_id,
          actor: socket.assigns.current_user
        )

      # Update name/position (fields accepted by :update action)
      update_params = Map.take(params, ["name", "position"])
      Magus.Chat.update_folder!(folder, update_params, actor: socket.assigns.current_user)

      # Move parent if changed
      new_parent_id = params["parent_id"]
      current_parent_id = if folder.parent_id, do: to_string(folder.parent_id), else: nil

      if new_parent_id != current_parent_id do
        Magus.Chat.move_folder!(folder, %{parent_id: new_parent_id},
          actor: socket.assigns.current_user
        )
      end
    else
      params = Map.put(params, "kind", :conversations)
      Magus.Chat.create_folder!(params, actor: socket.assigns.current_user)
    end

    {:noreply,
     socket
     |> assign(:show_folder_modal, false)
     |> assign(:editing_folder_id, nil)}
  end

  def handle_event("delete_conversation", %{"id" => id}, socket) do
    conversation = Magus.Chat.get_conversation!(id, actor: socket.assigns.current_user)
    Magus.Chat.soft_delete_conversation!(conversation, actor: socket.assigns.current_user)
    {:noreply, socket}
  end

  defp folder_options(folders, editing_folder_id) do
    folders
    |> Enum.reject(fn folder -> editing_folder_id && folder.id == editing_folder_id end)
    |> Enum.map(fn folder -> {folder.name, folder.id} end)
  end

  defp assign_folder_form(socket, params) do
    form = to_form(params, as: :folder)
    assign(socket, :folder_form, form)
  end
end
