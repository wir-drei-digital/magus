defmodule MagusWeb.Workbench.Resources.FileBrowserView.Grid do
  @moduledoc false
  use MagusWeb, :live_component

  import MagusWeb.Workbench.Components.InlineEditActions

  alias MagusWeb.Workbench.Resources.FileBrowserView.EmptyState

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="grid grid-cols-[repeat(auto-fill,minmax(170px,1fr))] gap-3 p-4 content-start"
    >
      <div :if={@entries_empty? and not @new_folder_open?} class="col-span-full">
        <EmptyState.empty_state scope={@scope} />
      </div>

      <form
        :if={@new_folder_open?}
        phx-submit="submit_new_folder"
        class="border border-wb-accent rounded-lg overflow-hidden bg-wb-surface"
      >
        <div class="aspect-[4/5] flex flex-col">
          <div class="flex-1 min-h-0 flex items-center justify-center bg-wb-accent/10 text-wb-accent">
            <.icon name="lucide-folder" class="w-10 h-10" />
          </div>
          <div class="flex items-center gap-1 border-t border-wb-border bg-wb-bg px-1 py-1">
            <input
              type="text"
              name="name"
              autofocus
              placeholder={gettext("New folder")}
              phx-keydown="cancel_new_folder"
              phx-key="Escape"
              class="flex-1 min-w-0 text-xs bg-transparent px-1 py-0.5 focus:outline-none"
            />
            <.inline_edit_actions
              cancel_event="cancel_new_folder"
              save_label={gettext("Create folder")}
              size={:sm}
            />
          </div>
        </div>
      </form>

      <div id={"#{@id}-stream"} phx-update="stream" class="contents">
        <div
          :for={{dom_id, entry} <- @entries_stream}
          id={dom_id}
          data-entry-kind={entry.kind}
          data-entry-id={entry.id}
          phx-click="open_entry"
          phx-value-kind={entry.kind}
          phx-value-id={entry.id}
          phx-hook=".RightClick"
          class={[
            "group relative cursor-pointer border border-wb-border rounded-lg overflow-hidden hover:border-wb-accent",
            entry.kind == :folder && "bg-wb-surface"
          ]}
        >
          <div class="aspect-[4/5] flex flex-col">
            <div class={[
              "flex-1 min-h-0 overflow-hidden flex items-center justify-center",
              entry.kind == :folder && "bg-wb-accent/10 text-wb-accent",
              entry.kind == :file && "bg-wb-bg"
            ]}>
              <%= if entry.kind == :file and entry.file_type == :image and entry.thumb_url do %>
                <img
                  src={entry.thumb_url}
                  alt={entry.name}
                  loading="lazy"
                  class="block object-cover w-full h-full"
                />
              <% else %>
                <.icon name={entry.icon || "lucide-file"} class="w-10 h-10" />
              <% end %>
            </div>
            <div class="px-2 py-1.5 border-t border-wb-border text-xs">
              <div class="truncate flex items-center gap-1">
                <span class="truncate">{entry.name}</span>
                <span :if={entry.badge} class="text-[10px] text-wb-text-dim">· {entry.badge}</span>
              </div>
            </div>
          </div>
        </div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".RightClick">
        export default {
          mounted() {
            this.el.addEventListener("contextmenu", (e) => {
              e.preventDefault();
              this.pushEvent("open_menu", {
                kind: this.el.dataset.entryKind,
                id: this.el.dataset.entryId,
                x: e.clientX,
                y: e.clientY
              });
            });
          }
        }
      </script>
    </div>
    """
  end
end
