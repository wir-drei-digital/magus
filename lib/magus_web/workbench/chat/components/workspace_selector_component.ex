defmodule MagusWeb.ChatLive.Components.WorkspaceSelectorComponent do
  @moduledoc """
  Workspace selector dropdown for switching between personal space and workspaces.

  Renders a compact dropdown at the top of the conversation sidebar.
  When a workspace is selected, conversations and resources are filtered
  to that workspace's context.
  """
  use MagusWeb, :live_component

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:dropdown_open, fn -> false end)
      |> assign_new(:can_create_workspace, fn -> false end)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="relative" id={@id}>
      <button
        type="button"
        class="flex items-center gap-2 w-full px-3 py-1.5 text-sm text-base-content/70 rounded-lg hover:bg-base-200 hover:text-base-content transition-colors"
        phx-click="toggle_workspace_dropdown"
        phx-target={@myself}
      >
        <div class="flex items-center gap-2 flex-1 min-w-0">
          <%= if @current_workspace do %>
            <span class="flex items-center justify-center w-6 h-6 rounded bg-primary/10 text-primary text-xs font-bold flex-shrink-0">
              {String.first(@current_workspace.name)}
            </span>
            <span class="truncate">{@current_workspace.name}</span>
          <% else %>
            <span class="flex items-center justify-center w-6 h-6 rounded bg-base-300 text-base-content/60 flex-shrink-0">
              <.icon name="lucide-user" class="w-3.5 h-3.5" />
            </span>
            <span class="truncate">{gettext("Personal")}</span>
          <% end %>
        </div>
        <.icon
          name="lucide-chevrons-up-down"
          class="w-4 h-4 text-base-content/40 flex-shrink-0"
        />
      </button>

      <div
        :if={@dropdown_open}
        class="absolute left-0 right-0 top-full mt-1 z-30 bg-base-100 border border-base-300 rounded-lg shadow-lg overflow-hidden"
      >
        <%!-- Personal space option --%>
        <button
          type="button"
          class={[
            "flex items-center gap-2 w-full px-3 py-2.5 text-sm hover:bg-base-200 transition-colors",
            !@current_workspace && "bg-primary/5 text-primary font-medium"
          ]}
          phx-click="select_workspace"
          phx-value-workspace-id=""
          phx-target={@myself}
        >
          <span class="flex items-center justify-center w-6 h-6 rounded bg-base-300 text-base-content/60 flex-shrink-0">
            <.icon name="lucide-user" class="w-3.5 h-3.5" />
          </span>
          <span>{gettext("Personal")}</span>
          <.icon
            :if={!@current_workspace}
            name="lucide-check"
            class="w-4 h-4 ml-auto"
          />
        </button>

        <%= if @workspaces != [] do %>
          <div class="border-t border-base-300">
            <span class="block px-3 py-1.5 text-xs text-base-content/50 uppercase tracking-wider">
              {gettext("Workspaces")}
            </span>
          </div>

          <div
            :for={ws <- @workspaces}
            class={[
              "flex items-center gap-2 w-full px-3 py-2.5 text-sm hover:bg-base-200 transition-colors group",
              @current_workspace && @current_workspace.id == ws.id &&
                "bg-primary/5 text-primary font-medium"
            ]}
          >
            <button
              type="button"
              class="flex items-center gap-2 flex-1 min-w-0"
              phx-click="select_workspace"
              phx-value-workspace-id={ws.id}
              phx-target={@myself}
            >
              <span class="flex items-center justify-center w-6 h-6 rounded bg-primary/10 text-primary text-xs font-bold flex-shrink-0">
                {String.first(ws.name)}
              </span>
              <span class="truncate">{ws.name}</span>
              <.icon
                :if={@current_workspace && @current_workspace.id == ws.id}
                name="lucide-check"
                class="w-4 h-4 ml-auto"
              />
            </button>
            <.link
              navigate={~p"/workspaces/#{ws.slug}"}
              class="opacity-0 group-hover:opacity-100 btn btn-ghost btn-xs btn-square flex-shrink-0"
              title={gettext("Manage workspace")}
            >
              <.icon name="lucide-settings" class="w-3.5 h-3.5" />
            </.link>
          </div>
        <% end %>

        <%!-- Create workspace button --%>
        <div :if={@can_create_workspace} class="border-t border-base-300">
          <button
            type="button"
            class="flex items-center gap-2 w-full px-3 py-2.5 text-sm text-base-content/60 hover:text-base-content hover:bg-base-200 transition-colors"
            phx-click="create_workspace"
            phx-target={@myself}
          >
            <.icon name="lucide-plus" class="w-4 h-4" />
            <span>{gettext("Create workspace")}</span>
          </button>
        </div>
      </div>

      <%!-- Click-away overlay to close dropdown --%>
      <div
        :if={@dropdown_open}
        class="fixed inset-0 z-20"
        phx-click="toggle_workspace_dropdown"
        phx-target={@myself}
      />
    </div>
    """
  end

  @impl true
  def handle_event("toggle_workspace_dropdown", _params, socket) do
    {:noreply, assign(socket, :dropdown_open, !socket.assigns.dropdown_open)}
  end

  @impl true
  def handle_event("select_workspace", %{"workspace-id" => ""}, socket) do
    send(self(), {:workspace_changed, nil})
    {:noreply, assign(socket, dropdown_open: false)}
  end

  def handle_event("select_workspace", %{"workspace-id" => workspace_id}, socket) do
    workspace = Enum.find(socket.assigns.workspaces, &(&1.id == workspace_id))
    send(self(), {:workspace_changed, workspace})
    {:noreply, assign(socket, dropdown_open: false)}
  end

  def handle_event("create_workspace", _params, socket) do
    send(self(), :show_create_workspace)
    {:noreply, assign(socket, dropdown_open: false)}
  end
end
