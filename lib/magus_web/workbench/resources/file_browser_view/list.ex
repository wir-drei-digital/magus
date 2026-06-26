defmodule MagusWeb.Workbench.Resources.FileBrowserView.List do
  @moduledoc false
  use MagusWeb, :live_component

  import MagusWeb.Workbench.Components.InlineEditActions

  alias MagusWeb.Workbench.Resources.FileBrowserView.EmptyState

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div :if={@entries_empty? and not @new_folder_open?}>
        <EmptyState.empty_state scope={@scope} />
      </div>

      <table
        :if={not @entries_empty? or @new_folder_open?}
        class="w-full text-sm border-collapse"
      >
        <thead class="text-[11px] uppercase tracking-wide text-wb-text-dim bg-wb-surface">
          <tr>
            <th class="px-3 py-2 text-left">
              <button type="button" phx-click="set_sort" phx-value-sort={toggle_sort(@sort, "name")}>
                {gettext("Name")} {sort_arrow(@sort, "name")}
              </button>
            </th>
            <th class="px-3 py-2 text-left">{gettext("Type")}</th>
            <th class="px-3 py-2 text-left">{gettext("Owner")}</th>
            <th class="px-3 py-2 text-left">
              <button
                type="button"
                phx-click="set_sort"
                phx-value-sort={toggle_sort(@sort, "updated_at")}
              >
                {gettext("Modified")} {sort_arrow(@sort, "updated_at")}
              </button>
            </th>
            <th class="px-3 py-2 text-left">
              <button
                type="button"
                phx-click="set_sort"
                phx-value-sort={toggle_sort(@sort, "file_size")}
              >
                {gettext("Size")} {sort_arrow(@sort, "file_size")}
              </button>
            </th>
            <th class="px-3 py-2 text-left">{gettext("Source")}</th>
            <th class="w-10"></th>
          </tr>
        </thead>
        <tbody :if={@new_folder_open?}>
          <tr>
            <td colspan="7" class="p-2">
              <form phx-submit="submit_new_folder" class="flex items-center gap-2">
                <.icon name="lucide-folder" class="w-4 h-4 text-wb-text-dim shrink-0" />
                <input
                  type="text"
                  name="name"
                  autofocus
                  placeholder={gettext("New folder")}
                  phx-keydown="cancel_new_folder"
                  phx-key="Escape"
                  class="bg-wb-surface border border-wb-border rounded-md px-2 py-1 text-xs"
                />
                <.inline_edit_actions
                  cancel_event="cancel_new_folder"
                  save_label={gettext("Create folder")}
                  size={:sm}
                />
              </form>
            </td>
          </tr>
        </tbody>
        <tbody phx-update="stream" id={"#{@id}-body"}>
          <tr
            :for={{dom_id, entry} <- @entries_stream}
            id={dom_id}
            data-entry-kind={entry.kind}
            data-entry-id={entry.id}
            phx-click="open_entry"
            phx-value-kind={entry.kind}
            phx-value-id={entry.id}
            phx-hook=".RightClick"
            class="group border-b border-wb-border cursor-pointer hover:bg-wb-hover"
          >
            <td class="px-3 py-2">
              <span class="inline-flex items-center gap-2">
                <.icon name={entry.icon || "lucide-file"} class="w-4 h-4 text-wb-text-dim" />
                <span class="truncate">{entry.name}</span>
                <span
                  :if={entry.badge}
                  class="text-[10px] border border-wb-border rounded-full px-1.5 py-px text-wb-text-dim"
                >
                  {entry.badge}
                </span>
              </span>
            </td>
            <td class="px-3 py-2 text-wb-text-dim">{type_label(entry)}</td>
            <td class="px-3 py-2 text-wb-text-dim truncate">{entry.owner_name || "-"}</td>
            <td class="px-3 py-2 text-wb-text-dim whitespace-nowrap">
              {format_dt(entry.modified_at)}
            </td>
            <td class="px-3 py-2 text-wb-text-dim whitespace-nowrap">{format_size(entry)}</td>
            <td class="px-3 py-2 text-wb-text-dim">{format_source(entry)}</td>
            <td class="px-3 py-2 text-right">
              <button
                type="button"
                phx-click="open_menu"
                phx-value-kind={entry.kind}
                phx-value-id={entry.id}
                phx-value-x="0"
                phx-value-y="0"
                class="opacity-0 group-hover:opacity-100"
              >
                ⋯
              </button>
            </td>
          </tr>
        </tbody>
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
      </table>
    </div>
    """
  end

  defp toggle_sort(current, key) do
    case current do
      ^key <> ":asc" -> "#{key}:desc"
      ^key <> ":desc" -> "#{key}:asc"
      _ -> "#{key}:desc"
    end
  end

  defp sort_arrow(current, key) do
    cond do
      current == "#{key}:asc" -> "↑"
      current == "#{key}:desc" -> "↓"
      true -> ""
    end
  end

  defp type_label(%{kind: :folder}), do: gettext("Folder")
  defp type_label(%{kind: :file, file_type: :image}), do: gettext("Image")
  defp type_label(%{kind: :file, file_type: :video}), do: gettext("Video")
  defp type_label(%{kind: :file, file_type: :document}), do: gettext("Document")
  defp type_label(%{kind: :file, file_type: :text}), do: gettext("Text")
  defp type_label(%{kind: :file, file_type: :email}), do: gettext("Email")

  defp type_label(%{kind: :file, file_type: t}) when not is_nil(t),
    do: t |> to_string() |> String.capitalize()

  defp type_label(_), do: "-"

  defp format_size(%{kind: :folder}), do: "-"
  defp format_size(%{size: nil}), do: "-"
  defp format_size(%{size: b}) when b < 1024, do: "#{b} B"
  defp format_size(%{size: b}) when b < 1024 * 1024, do: "#{Float.round(b / 1024, 1)} KB"
  defp format_size(%{size: b}), do: "#{Float.round(b / (1024 * 1024), 1)} MB"

  defp format_source(%{kind: :folder}), do: "-"
  defp format_source(%{source: :user}), do: gettext("Upload")
  defp format_source(%{source: :agent}), do: gettext("Generated")
  defp format_source(%{source: :connector}), do: gettext("Synced")
  defp format_source(_), do: "-"

  defp format_dt(nil), do: "-"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %Y")
  defp format_dt(_), do: "-"
end
