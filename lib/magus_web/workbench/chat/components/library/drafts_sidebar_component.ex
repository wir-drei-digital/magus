defmodule MagusWeb.ChatLive.Components.Library.DraftsSidebarComponent do
  @moduledoc """
  Drafts sidebar component for listing and managing draft documents.

  Displays all drafts for the current conversation, allowing the user to
  switch between drafts, rename, or delete them.
  """

  use MagusWeb, :live_component
  use MagusWeb.Live.Shared.ComponentUtils

  def render(assigns) do
    ~H"""
    <div class="space-y-1">
      <div
        :for={draft <- @drafts}
        id={"draft-#{draft.id}"}
        class={[
          "sidebar-item cursor-pointer",
          @active_draft_id == draft.id && "ring-1 ring-primary"
        ]}
        phx-click="open_draft"
        phx-value-id={draft.id}
        phx-target={@myself}
      >
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-2 min-w-0">
            <.icon name="lucide-file-text" class="w-4 h-4 flex-shrink-0" />
            <span class="font-medium text-sm truncate">{draft.title}</span>
          </div>
          <div class="flex items-center gap-1">
            <span class="badge badge-xs badge-ghost">v{draft.version}</span>
            <.popover_menu id={"draft-menu-#{draft.id}"} class="w-40">
              <:trigger>
                <.icon name="lucide-more-vertical" class="w-4 h-4" />
              </:trigger>
              <:item>
                <button
                  phx-click="open_draft"
                  phx-value-id={draft.id}
                  phx-target={@myself}
                >
                  <.icon name="lucide-eye" class="w-4 h-4" /> {gettext("Open")}
                </button>
              </:item>
              <:item class="text-error">
                <button
                  phx-click="delete_draft"
                  phx-value-id={draft.id}
                  phx-target={@myself}
                  data-confirm={gettext("Are you sure you want to delete this draft?")}
                >
                  <.icon name="lucide-trash-2" class="w-4 h-4" /> {gettext("Delete")}
                </button>
              </:item>
            </.popover_menu>
          </div>
        </div>
      </div>

      <div :if={@drafts == []} class="text-center text-base-content/50 py-4">
        <.icon name="lucide-file-text" class="w-8 h-8 mx-auto mb-2 opacity-50" />
        <p class="text-sm">{gettext("No drafts yet.")}</p>
        <p class="text-xs mt-1">{gettext("Ask the AI to write a draft.")}</p>
      </div>
    </div>
    """
  end

  def mount(socket) do
    {:ok,
     socket
     |> assign(:drafts, [])
     |> assign(:active_draft_id, nil)}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  def handle_event("open_draft", %{"id" => id}, socket) do
    notify_parent({:switch_draft, id})
    {:noreply, socket}
  end

  def handle_event("delete_draft", %{"id" => id}, socket) do
    notify_parent({:delete_draft, id})
    {:noreply, socket}
  end
end
