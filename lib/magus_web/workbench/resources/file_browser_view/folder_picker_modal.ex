defmodule MagusWeb.Workbench.Resources.FileBrowserView.FolderPickerModal do
  @moduledoc false
  use MagusWeb, :live_component

  alias Magus.Chat

  @impl true
  def update(assigns, socket) do
    user = assigns.user
    workspace_id = assigns.workspace_id

    folders =
      if workspace_id,
        do: Chat.list_workspace_folders!(workspace_id, %{kinds: [:files, :mixed]}, actor: user),
        else: Chat.my_folders!(%{kinds: [:files, :mixed]}, actor: user)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:folders, folders)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="fixed inset-0 z-40 flex items-center justify-center bg-black/40">
      <div class="bg-wb-bg border border-wb-border rounded-lg w-full max-w-md p-4 shadow-xl">
        <div class="flex items-center justify-between mb-2">
          <h3 class="text-sm font-medium">{gettext("Move to...")}</h3>
          <button type="button" phx-click="cancel_move" aria-label={gettext("Close")}>
            <.icon name="lucide-x" class="w-4 h-4" />
          </button>
        </div>

        <div class="max-h-72 overflow-auto border border-wb-border rounded-md text-sm">
          <button
            type="button"
            phx-click="confirm_move"
            phx-value-folder-id=""
            class="w-full text-left px-3 py-1.5 hover:bg-wb-hover flex items-center gap-2"
          >
            <.icon name="lucide-house" class="w-4 h-4 text-wb-text-dim" /> {gettext(
              "Root (no folder)"
            )}
          </button>

          <button
            :for={f <- @folders}
            type="button"
            phx-click="confirm_move"
            phx-value-folder-id={f.id}
            class="w-full text-left px-3 py-1.5 hover:bg-wb-hover flex items-center gap-2"
            disabled={f.id == @move_target.id}
          >
            <.icon name="lucide-folder" class="w-4 h-4 text-wb-text-dim" /> {f.name ||
              gettext("Untitled")}
          </button>
        </div>
      </div>
    </div>
    """
  end
end
