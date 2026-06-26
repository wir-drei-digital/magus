defmodule MagusWeb.ChatLive.Components.Library.FilesSidebarComponent do
  @moduledoc """
  Files sidebar component for uploading and managing document files.
  """

  use MagusWeb, :live_component

  alias MagusWeb.Workbench.UploadHelpers

  @max_uploads 10
  @max_file_size 50_000_000

  def render(assigns) do
    ~H"""
    <form
      phx-change="validate_upload"
      phx-submit="upload_files"
      phx-target={@myself}
      class="flex flex-col relative rounded-lg transition-all duration-200"
      phx-drop-target={@uploads.file_uploads.ref}
      id="files-drop-zone"
      phx-hook=".DropZone"
    >
      <%!-- Drop zone overlay (shown when dragging) --%>
      <div
        id="files-drop-overlay"
        class="hidden absolute inset-0 bg-primary/10 border-2 border-dashed border-primary rounded-lg z-10 pointer-events-none"
      >
        <div class="flex flex-col items-center justify-center h-full">
          <.icon name="lucide-cloud-upload" class="w-10 h-10 text-primary animate-bounce" />
          <p class="text-sm font-medium text-primary mt-2">{gettext("Drop files here")}</p>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".DropZone">
        export default {
          mounted() {
            this.dragCounter = 0;
            this.overlay = this.el.querySelector('#files-drop-overlay');

            this.el.addEventListener('dragenter', (e) => {
              e.preventDefault();
              this.dragCounter++;
              if (this.dragCounter === 1) {
                this.overlay.classList.remove('hidden');
                this.overlay.classList.add('flex');
              }
            });

            this.el.addEventListener('dragleave', (e) => {
              e.preventDefault();
              this.dragCounter--;
              if (this.dragCounter === 0) {
                this.overlay.classList.add('hidden');
                this.overlay.classList.remove('flex');
              }
            });

            this.el.addEventListener('dragover', (e) => {
              e.preventDefault();
            });

            this.el.addEventListener('drop', (e) => {
              this.dragCounter = 0;
              this.overlay.classList.add('hidden');
              this.overlay.classList.remove('flex');
            });
          }
        }
      </script>

      <%!-- File Scope Toggle --%>
      <div role="tablist" class="tabs tabs-lift tabs-sm mb-3">
        <button
          :if={@conversation_id}
          type="button"
          role="tab"
          phx-click="set_file_scope"
          phx-value-scope="conversation"
          phx-target={@myself}
          class={"tab #{if @file_scope == :conversation, do: "tab-active"}"}
          title={gettext("Files for this conversation only")}
        >
          {gettext("Chat")}
        </button>
        <button
          :if={@folder_id}
          type="button"
          role="tab"
          phx-click="set_file_scope"
          phx-value-scope="folder"
          phx-target={@myself}
          class={"tab #{if @file_scope == :folder, do: "tab-active"}"}
          title={gettext("Files for this folder")}
        >
          {gettext("Folder")}
        </button>
        <button
          :if={@workspace_id}
          type="button"
          role="tab"
          phx-click="set_file_scope"
          phx-value-scope="workspace"
          phx-target={@myself}
          class={"tab #{if @file_scope == :workspace, do: "tab-active"}"}
          title={gettext("Files shared with workspace")}
        >
          {gettext("Team")}
        </button>
        <button
          type="button"
          role="tab"
          phx-click="set_file_scope"
          phx-value-scope="global"
          phx-target={@myself}
          class={"tab #{if @file_scope == :global, do: "tab-active"}"}
          title={gettext("Files available in all conversations")}
        >
          {gettext("Global")}
        </button>
      </div>

      <%!-- Upload Button --%>
      <div class="mb-3">
        <.live_file_input
          upload={@uploads.file_uploads}
          class="file-input file-input-bordered file-input-sm w-full"
        />
      </div>

      <%!-- Upload Progress --%>
      <div :if={Enum.any?(@uploads.file_uploads.entries)} class="mb-3 space-y-2">
        <div :for={entry <- @uploads.file_uploads.entries} class="flex items-center gap-2">
          <span class="text-sm truncate flex-1">{entry.client_name}</span>
          <span class="text-xs text-base-content/50">{entry.progress}%</span>
          <progress class="progress progress-primary w-20" value={entry.progress} max="100" />
          <button
            type="button"
            phx-click="cancel_upload"
            phx-value-ref={entry.ref}
            phx-target={@myself}
            class="btn btn-ghost btn-xs btn-square"
          >
            <.icon name="lucide-x" class="w-4 h-4" />
          </button>
        </div>

        <%!-- Upload errors --%>
        <%= for entry <- @uploads.file_uploads.entries, {err, _} <- upload_errors(@uploads.file_uploads, entry) do %>
          <p class="text-error text-xs">
            {entry.client_name}: {error_to_string(err)}
          </p>
        <% end %>

        <button type="submit" class="btn btn-primary btn-sm w-full mt-2">
          <.icon name="lucide-upload" class="w-4 h-4" />
          {ngettext(
            "Upload %{count} file",
            "Upload %{count} files",
            length(@uploads.file_uploads.entries),
            count: length(@uploads.file_uploads.entries)
          )}
        </button>
      </div>

      <%!-- Files List --%>
      <div
        class="space-y-1"
        id="draggable-files"
        phx-hook="DraggableFiles"
      >
        <div
          :for={file <- @files}
          id={"file-#{file.id}"}
          class="sidebar-item cursor-grab active:cursor-grabbing"
          draggable={if file.status == :ready, do: "true", else: "false"}
          data-file-id={file.id}
          data-file-name={file.name}
          data-file-type={file.type}
        >
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-2 min-w-0">
              <.icon name={type_icon(file.type)} class="w-4 h-4 flex-shrink-0" />
              <span class="font-medium text-sm truncate">{file.name}</span>
            </div>
            <div class="flex items-center gap-1">
              <span class={"badge badge-xs #{status_badge_class(file.status)}"}>
                {file.status}
              </span>
              <%!-- Context Menu Dropdown --%>
              <.popover_menu :if={file.status == :ready} id={"file-menu-#{file.id}"} class="w-40">
                <:trigger>
                  <.icon name="lucide-more-vertical" class="w-4 h-4" />
                </:trigger>
                <:item>
                  <a href={~p"/files/#{file.id}/download"}>
                    <.icon name="lucide-download" class="w-4 h-4" /> {gettext("Download")}
                  </a>
                </:item>
                <:item :if={@file_scope != :global}>
                  <button
                    phx-click="move_to_global"
                    phx-value-id={file.id}
                    phx-target={@myself}
                  >
                    <.icon name="lucide-globe" class="w-4 h-4" /> {gettext("Move to Global")}
                  </button>
                </:item>
                <:item :if={@file_scope != :folder && @folder_id}>
                  <button
                    phx-click="move_to_folder"
                    phx-value-id={file.id}
                    phx-target={@myself}
                  >
                    <.icon name="lucide-folder" class="w-4 h-4" /> {gettext("Move to Folder")}
                  </button>
                </:item>
                <:item :if={@file_scope != :conversation && @conversation_id}>
                  <button
                    phx-click="move_to_conversation"
                    phx-value-id={file.id}
                    phx-target={@myself}
                  >
                    <.icon name="lucide-message-square" class="w-4 h-4" /> {gettext("Move to Chat")}
                  </button>
                </:item>
                <:item class="text-error">
                  <button
                    phx-click="delete_file"
                    phx-value-id={file.id}
                    phx-target={@myself}
                  >
                    <.icon name="lucide-trash-2" class="w-4 h-4" /> {gettext("Delete")}
                  </button>
                </:item>
              </.popover_menu>
            </div>
          </div>
          <div :if={file.status == :processing} class="mt-2">
            <progress class="progress progress-primary w-full" />
          </div>
          <p :if={file.status == :ready} class="text-xs text-base-content/50 mt-1">
            {file.chunk_count} chunks
          </p>
          <p :if={file.status == :error} class="text-xs text-error mt-1">
            {file.error_message}
          </p>
        </div>

        <div :if={@files == []} class="text-center text-base-content/50 py-8">
          <.icon name="lucide-folder-open" class="w-12 h-12 mx-auto mb-2 opacity-50" />
          <p class="text-sm">{gettext("No files yet.")}</p>
          <p class="text-xs mt-1">{gettext("Drop files here or click + to upload.")}</p>
        </div>
      </div>
    </form>
    """
  end

  def mount(socket) do
    {:ok,
     socket
     |> assign(:files, [])
     |> allow_upload(:file_uploads,
       accept: :any,
       max_entries: @max_uploads,
       max_file_size: @max_file_size,
       auto_upload: false
     )}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:file_scope, fn ->
        # Default to conversation scope if a conversation is open, otherwise global
        if assigns[:conversation_id], do: :conversation, else: :global
      end)
      |> load_files()

    {:ok, socket}
  end

  # Event handlers
  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :file_uploads, ref)}
  end

  def handle_event("upload_files", _params, socket) do
    current_user = socket.assigns.current_user
    entries = socket.assigns.uploads.file_uploads.entries
    files = Enum.map(entries, &%{name: &1.client_name, size: &1.client_size})

    case Magus.Usage.PolicyEnforcer.check_file_uploads(current_user, files) do
      {:ok, :allowed} ->
        do_upload_files(socket)

      {:error, message} ->
        send(self(), {__MODULE__, {:flash, :error, message}})
        {:noreply, socket}
    end
  end

  def handle_event("set_file_scope", %{"scope" => scope}, socket) do
    scope = String.to_existing_atom(scope)

    {:noreply,
     socket
     |> assign(:file_scope, scope)
     |> load_files()}
  end

  def handle_event("delete_file", %{"id" => id}, socket) do
    case Magus.Files.get_file(id, actor: socket.assigns.current_user) do
      {:ok, file} ->
        # Delete file from storage
        Magus.Files.Storage.delete(file.file_path)
        # Delete file (cascades to chunks)
        Magus.Files.delete_file!(file, actor: socket.assigns.current_user)
        {:noreply, load_files(socket)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "File not found")}
    end
  end

  def handle_event("move_to_global", %{"id" => id}, socket) do
    move_file(socket, id, %{conversation_id: nil, folder_id: nil})
  end

  def handle_event("move_to_folder", %{"id" => id}, socket) do
    folder_id = socket.assigns[:folder_id]
    move_file(socket, id, %{conversation_id: nil, folder_id: folder_id})
  end

  def handle_event("move_to_conversation", %{"id" => id}, socket) do
    conversation_id = socket.assigns[:conversation_id]
    move_file(socket, id, %{conversation_id: conversation_id, folder_id: nil})
  end

  defp move_file(socket, id, attrs) do
    case Magus.Files.get_file(id, actor: socket.assigns.current_user) do
      {:ok, file} ->
        case Magus.Files.move_file_to_context(file, attrs, actor: socket.assigns.current_user) do
          {:ok, _} ->
            {:noreply, load_files(socket)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to move file")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "File not found")}
    end
  end

  # Private functions

  defp do_upload_files(socket) do
    UploadHelpers.do_upload(socket, upload_name: :file_uploads, reload_fun: &load_files/1)
  end

  defp load_files(socket) do
    conversation_id = socket.assigns[:conversation_id]
    folder_id = socket.assigns[:folder_id]
    current_user = socket.assigns.current_user
    scope = socket.assigns.file_scope

    files =
      case scope do
        :global ->
          case Magus.Files.list_global_files(current_user.id, actor: current_user) do
            {:ok, files} -> files
            _ -> []
          end

        :workspace ->
          workspace_id = socket.assigns[:workspace_id]

          if workspace_id do
            case Magus.Files.list_files_for_workspace(workspace_id, actor: current_user) do
              {:ok, files} -> files
              _ -> []
            end
          else
            []
          end

        :folder when not is_nil(folder_id) ->
          case Magus.Files.list_files_for_folder(folder_id, actor: current_user) do
            {:ok, files} -> files
            _ -> []
          end

        :conversation when not is_nil(conversation_id) ->
          case Magus.Files.list_files_for_conversation(conversation_id, actor: current_user) do
            {:ok, files} -> files
            _ -> []
          end

        _ ->
          # Default to conversation if available, otherwise empty
          if not is_nil(conversation_id) do
            case Magus.Files.list_files_for_conversation(conversation_id,
                   actor: current_user
                 ) do
              {:ok, files} -> files
              _ -> []
            end
          else
            []
          end
      end

    assign(socket, :files, files)
  end

  defp type_icon(:document), do: "lucide-file"
  defp type_icon(:text), do: "lucide-file-text"
  defp type_icon(:image), do: "lucide-image"
  defp type_icon(:video), do: "lucide-film"
  defp type_icon(:email), do: "lucide-mail"
  defp type_icon(_), do: "lucide-file"

  defp status_badge_class(:pending), do: "badge-warning"
  defp status_badge_class(:processing), do: "badge-info"
  defp status_badge_class(:ready), do: "badge-success"
  defp status_badge_class(:error), do: "badge-error"
  defp status_badge_class(_), do: "badge-neutral"

  defp error_to_string(:too_large), do: gettext("File too large (max 50MB)")
  defp error_to_string(:not_accepted), do: gettext("File type not accepted")
  defp error_to_string(:too_many_files), do: gettext("Too many files (max 10)")
  defp error_to_string(err), do: to_string(err)
end
