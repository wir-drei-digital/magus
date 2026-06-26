defmodule MagusWeb.Workbench.Layout.WorkspaceSelector do
  @moduledoc """
  Compact workspace selector rendered at the top of the nav pane.
  Shows the current workspace name + a small initial glyph. Clicking
  the row opens a DaisyUI dropdown listing the user's Personal workspace
  (the implicit nil-workspace bucket), their team workspaces, and a
  "New workspace" action.

  Events emitted to parent LiveView:
    - `phx-click="select_workspace"` with `phx-value-id=<ws.id>` (or empty
      string for the Personal workspace)
    - `phx-click="open_create_workspace"` (no params)
  """
  use MagusWeb, :live_component

  alias Phoenix.LiveView.JS

  @impl true
  def render(assigns) do
    ~H"""
    <div data-workspace-selector class="px-3 pt-3 pb-2">
      <details class="group relative w-full">
        <summary class="flex items-center gap-2.5 pl-1.5 pr-2 py-1.5 rounded-xl bg-wb-surface-2 hover:bg-wb-hover border border-wb-border-strong cursor-pointer list-none transition-colors">
          <div class="w-8 h-8 rounded-lg bg-wb-accent text-white flex items-center justify-center text-sm font-bold shadow-sm">
            {workspace_initial(@current_workspace)}
          </div>
          <span class="flex-1 text-sm font-semibold truncate text-wb-text">
            {workspace_name(@current_workspace)}
          </span>
          <.icon name="lucide-chevron-down" class="w-4 h-4 text-wb-text-muted mr-1" />
        </summary>
        <ul class="absolute left-0 right-0 mt-1 bg-wb-surface border border-wb-border rounded-lg shadow-lg z-10 py-1">
          <li>
            <button
              type="button"
              data-workspace-personal
              phx-click="select_workspace"
              phx-value-id=""
              class={[
                "w-full text-left px-3 py-1.5 text-sm flex items-center gap-2 hover:bg-wb-hover transition-colors",
                is_nil(@current_workspace) && "text-wb-accent-soft"
              ]}
            >
              <.icon name="lucide-user" class="w-4 h-4 text-wb-text-muted" />
              <span class="truncate">Personal</span>
            </button>
          </li>
          <li :if={@workspaces != []} class="my-1 border-t border-wb-border" aria-hidden="true"></li>
          <li :for={ws <- @workspaces}>
            <button
              type="button"
              phx-click="select_workspace"
              phx-value-id={ws.id}
              class={[
                "w-full text-left px-3 py-1.5 text-sm flex items-center gap-2 hover:bg-wb-hover transition-colors",
                @current_workspace && @current_workspace.id == ws.id && "text-wb-accent-soft"
              ]}
            >
              <span class="truncate">{ws.name}</span>
            </button>
          </li>
          <li :if={@current_workspace} class="my-1 border-t border-wb-border" aria-hidden="true"></li>
          <li :if={@current_workspace}>
            <.link
              patch={"/workspaces/#{@current_workspace.slug}"}
              data-workspace-settings
              phx-click={JS.remove_attribute("open", to: {:closest, "details"})}
              class="w-full text-left px-3 py-1.5 text-sm flex items-center gap-2 text-wb-text hover:bg-wb-hover transition-colors"
            >
              <.icon name="lucide-settings" class="w-4 h-4 text-wb-text-muted" />
              <span>Workspace settings</span>
            </.link>
          </li>
          <li class="my-1 border-t border-wb-border" aria-hidden="true"></li>
          <li>
            <button
              type="button"
              phx-click="open_create_workspace"
              class="w-full text-left px-3 py-1.5 text-sm flex items-center gap-2 text-wb-accent-soft hover:bg-wb-hover transition-colors"
            >
              <.icon name="lucide-plus" class="w-4 h-4" /> New workspace
            </button>
          </li>
        </ul>
      </details>
    </div>
    """
  end

  defp workspace_name(nil), do: "Personal"
  defp workspace_name(%{name: name}), do: name

  defp workspace_initial(nil), do: "P"

  defp workspace_initial(%{name: name}) when is_binary(name) and name != "" do
    name |> String.first() |> String.upcase()
  end

  defp workspace_initial(_), do: "?"
end
