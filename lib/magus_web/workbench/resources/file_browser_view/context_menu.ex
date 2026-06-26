defmodule MagusWeb.Workbench.Resources.FileBrowserView.ContextMenu do
  @moduledoc false
  use MagusWeb, :live_component

  @impl true
  def render(assigns) do
    pos = "left: #{assigns.menu_for.x}px; top: #{assigns.menu_for.y}px;"
    assigns = assign(assigns, :pos_style, pos)

    ~H"""
    <div
      id={@id}
      phx-click-away="close_menu"
      style={@pos_style}
      class="fixed z-50 w-56 bg-wb-bg border border-wb-border rounded-md shadow-lg py-1 text-xs"
    >
      <%= if @menu_for.kind == "file" and @scope != "trash" do %>
        <.menu_btn
          event="open_entry"
          kind="file"
          id={@menu_for.id}
          icon="lucide-arrow-up-right"
          label={gettext("Open in new tab")}
        />
        <.menu_btn
          event="download_entry"
          id={@menu_for.id}
          icon="lucide-download"
          label={gettext("Download")}
        />
        <.menu_btn
          event="open_entry_chat"
          id={@menu_for.id}
          icon="lucide-message-square"
          label={gettext("Open chat about this file")}
        />
        <.sep />
        <.menu_btn
          event="rename_entry"
          kind="file"
          id={@menu_for.id}
          icon="lucide-pencil"
          label={gettext("Rename")}
        />
        <.menu_btn
          event="move_entry"
          kind="file"
          id={@menu_for.id}
          icon="lucide-folder"
          label={gettext("Move to...")}
        />
        <.menu_btn
          event="toggle_template_entry"
          id={@menu_for.id}
          icon="lucide-star"
          label={gettext("Toggle template")}
        />
        <.menu_btn
          event="share_entry"
          kind="file"
          id={@menu_for.id}
          icon="lucide-share"
          label={gettext("Share to workspace")}
        />
        <.sep />
        <.menu_btn
          event="trash_entry"
          kind="file"
          id={@menu_for.id}
          icon="lucide-trash"
          label={gettext("Move to trash")}
          danger
        />
      <% end %>

      <%= if @menu_for.kind == "folder" and @scope != "trash" do %>
        <.menu_btn
          event="open_entry"
          kind="folder"
          id={@menu_for.id}
          icon="lucide-arrow-up-right"
          label={gettext("Open")}
        />
        <.sep />
        <.menu_btn
          event="rename_entry"
          kind="folder"
          id={@menu_for.id}
          icon="lucide-pencil"
          label={gettext("Rename")}
        />
        <.menu_btn
          event="move_entry"
          kind="folder"
          id={@menu_for.id}
          icon="lucide-folder"
          label={gettext("Move to...")}
        />
        <.menu_btn
          event="share_entry"
          kind="folder"
          id={@menu_for.id}
          icon="lucide-share"
          label={gettext("Share to workspace")}
        />
        <.sep />
        <.menu_btn
          event="trash_entry"
          kind="folder"
          id={@menu_for.id}
          icon="lucide-trash"
          label={gettext("Move to trash")}
          danger
        />
      <% end %>

      <%= if @scope == "trash" do %>
        <.menu_btn
          event="open_entry"
          kind={@menu_for.kind}
          id={@menu_for.id}
          icon="lucide-eye"
          label={gettext("View")}
        />
      <% end %>
    </div>
    """
  end

  attr :event, :string, required: true
  attr :id, :string, required: true
  attr :kind, :string, default: nil
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :danger, :boolean, default: false

  defp menu_btn(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@event}
      phx-value-id={@id}
      phx-value-kind={@kind}
      class={[
        "w-full flex items-center gap-2 px-3 py-1.5 hover:bg-wb-hover text-left",
        @danger && "text-error"
      ]}
    >
      <.icon name={@icon} class="w-3.5 h-3.5" />
      <span>{@label}</span>
    </button>
    """
  end

  defp sep(assigns), do: ~H|<div class="border-t border-wb-border my-1"></div>|
end
