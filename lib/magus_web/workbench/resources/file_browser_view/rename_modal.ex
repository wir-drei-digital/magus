defmodule MagusWeb.Workbench.Resources.FileBrowserView.RenameModal do
  @moduledoc false
  use MagusWeb, :live_component

  alias Magus.Chat
  alias Magus.Files

  @impl true
  def update(assigns, socket) do
    target = assigns.rename_target
    user = assigns.user

    current_name = lookup_name(target, user)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:current_name, current_name)}
  end

  defp lookup_name(%{kind: "file", id: id}, user) do
    case Files.get_file(id, actor: user) do
      {:ok, f} -> f.name || ""
      _ -> ""
    end
  end

  defp lookup_name(%{kind: "folder", id: id}, user) do
    case Chat.get_folder(id, actor: user) do
      {:ok, f} -> f.name || ""
      _ -> ""
    end
  end

  defp lookup_name(_, _), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="fixed inset-0 z-40 flex items-center justify-center bg-black/40">
      <div class="bg-wb-bg border border-wb-border rounded-lg w-full max-w-md p-4 shadow-xl">
        <div class="flex items-center justify-between mb-3">
          <h3 class="text-sm font-medium">{gettext("Rename")}</h3>
          <button type="button" phx-click="cancel_rename" aria-label={gettext("Close")}>
            <.icon name="lucide-x" class="w-4 h-4" />
          </button>
        </div>

        <form
          phx-submit="submit_rename"
          phx-value-kind={@rename_target.kind}
          phx-value-id={@rename_target.id}
          class="flex flex-col gap-2"
        >
          <input
            type="text"
            name="name"
            value={@current_name}
            autofocus
            phx-keydown="cancel_rename"
            phx-key="Escape"
            required
            minlength="1"
            class="w-full bg-wb-surface border border-wb-border rounded-md px-3 py-1.5 text-sm focus:outline-none focus:ring-1 focus:ring-wb-accent"
          />

          <div class="flex justify-end gap-2 mt-1">
            <button
              type="button"
              phx-click="cancel_rename"
              class="px-3 py-1 text-xs rounded-md border border-wb-border hover:bg-wb-hover"
            >
              {gettext("Cancel")}
            </button>
            <button
              type="submit"
              class="px-3 py-1 text-xs rounded-md bg-wb-accent text-white hover:opacity-90"
            >
              {gettext("Rename")}
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end
end
