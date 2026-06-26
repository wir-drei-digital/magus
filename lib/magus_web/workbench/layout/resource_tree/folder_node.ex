defmodule MagusWeb.Workbench.Layout.ResourceTree.FolderNode do
  @moduledoc """
  Renders a folder row recursively (children + leaf items + optional
  "+ New" affordance). Generic across resource types — receives a
  `%Node{kind: :folder}` plus context.
  """
  use MagusWeb, :html

  import MagusWeb.Workbench.Layout.ResourceTree.LeafNode

  attr :node, :map, required: true, doc: "%Node{kind: :folder}"
  attr :tree_id, :string, required: true, doc: "owning tree's @id, used to namespace DOM ids"
  attr :expanded_folders, :map, required: true
  attr :auto_expanded_ids, :any, default: nil
  attr :section, :string, required: true
  attr :editing_id, :any, default: nil

  def folder_node(assigns) do
    folder_id_str = to_string(assigns.node.id)
    persisted = Map.get(assigns.expanded_folders, folder_id_str, false)
    auto = assigns.auto_expanded_ids && MapSet.member?(assigns.auto_expanded_ids, assigns.node.id)
    expanded = persisted or auto
    editing? = assigns.editing_id == assigns.node.id

    assigns =
      assign(assigns,
        expanded: expanded,
        editing?: editing?,
        children: assigns.node.children || [],
        leaves: assigns.node.conversations || []
      )

    ~H"""
    <li
      id={"#{@tree_id}-folder-#{@node.id}"}
      data-folder-id={@node.id}
      data-resource-type={to_string(@node.resource_type)}
      data-section={@section}
      phx-hook={folder_drop_hook(@node)}
      class="list-none"
    >
      <div
        id={"#{@tree_id}-folder-drag-#{@node.id}"}
        data-folder-id={@node.id}
        data-section={@section}
        data-folder-header
        draggable={if @node.draggable, do: "true", else: "false"}
        phx-hook={if @node.draggable, do: "DraggableFolder", else: nil}
        class="group flex items-center gap-1"
      >
        <button
          :if={@node.chevron_event}
          type="button"
          phx-click={@node.chevron_event.event}
          phx-target={Map.get(@node.chevron_event, :target)}
          {phx_values(@node.chevron_event)}
          class="p-0.5 rounded hover:bg-wb-hover text-wb-text-dim hover:text-wb-text shrink-0"
          title={if @expanded, do: "Collapse", else: "Expand"}
          aria-expanded={if @expanded, do: "true", else: "false"}
        >
          <.icon
            name={if @expanded, do: "lucide-chevron-down", else: "lucide-chevron-right"}
            class="w-3 h-3"
          />
        </button>
        <button
          type="button"
          phx-click={row_event(@node)}
          phx-target={Map.get(@node.click_event || %{}, :target)}
          {row_phx_values(@node)}
          class="flex-1 flex items-center gap-2 px-2 py-1.5 rounded-md hover:bg-wb-hover text-wb-text-secondary hover:text-wb-text transition-colors min-w-0"
        >
          <.icon
            name={folder_icon(@node, @expanded)}
            class="w-3.5 h-3.5 shrink-0"
          />
          <span :if={!@editing?} class="flex-1 text-left text-sm truncate">{@node.label}</span>
          <form
            :if={@editing? and @node.editor}
            phx-submit={@node.editor.submit_event}
            phx-target={@node.editor.target}
            class="flex-1"
          >
            <input type="hidden" name="folder-id" value={@node.id} />
            <input
              type="text"
              name="name"
              value={@node.editor.value}
              autofocus
              phx-keydown={@node.editor.cancel_event}
              phx-key="Escape"
              phx-target={@node.editor.target}
              class="w-full bg-transparent border-b border-wb-accent text-sm focus:outline-none"
            />
          </form>
        </button>

        <div :if={!@editing? and @node.actions != []} class="flex items-center shrink-0">
          <%!-- Desktop: hover-revealed individual action buttons --%>
          <div
            data-actions="row"
            class="hidden md:flex items-center opacity-0 group-hover:opacity-100"
          >
            <button
              :for={action <- @node.actions}
              type="button"
              phx-click={action.event}
              phx-target={action.target}
              {action_values(action)}
              data-confirm={action.confirm}
              class={[
                "p-1 rounded hover:bg-wb-hover text-wb-text-dim",
                action.style == :danger && "hover:text-error",
                action.style == :default && "hover:text-wb-text"
              ]}
              title={action.title}
            >
              <.icon name={action.icon} class="w-3.5 h-3.5" />
            </button>
          </div>
          <%!-- Mobile: ellipsis menu since hover isn't available on touch --%>
          <.popover_menu
            id={"#{@tree_id}-folder-#{@node.id}-actions"}
            wrapper_class="relative inline-block md:hidden"
            trigger_class="p-1 rounded hover:bg-wb-hover text-wb-text-dim"
            class="w-44"
          >
            <:trigger>
              <.icon name="lucide-more-vertical" class="w-3.5 h-3.5" />
            </:trigger>
            <:item :for={action <- @node.actions}>
              <button
                type="button"
                phx-click={action.event}
                phx-target={action.target}
                {action_values(action)}
                data-confirm={action.confirm}
                class={action.style == :danger && "text-error"}
              >
                <.icon name={action.icon} class="w-4 h-4" />
                <span>{action.title}</span>
              </button>
            </:item>
          </.popover_menu>
        </div>
      </div>

      <ul
        :if={@expanded}
        class={
          [
            "pl-2 border-l border-wb-border space-y-0.5",
            # When the row carries a chevron (brain pages), pull the connector
            # line in to ml-2 so it drops straight from the chevron's center;
            # chevron-less folders (brain root, chat) keep the wider ml-3.
            if(@node.chevron_event, do: "ml-2", else: "ml-3")
          ]
        }
      >
        <.folder_node
          :for={child <- @children}
          :if={child.kind == :folder}
          node={child}
          tree_id={@tree_id}
          expanded_folders={@expanded_folders}
          auto_expanded_ids={@auto_expanded_ids}
          section={@section}
          editing_id={@editing_id}
        />
        <.leaf_node
          :for={leaf <- @leaves}
          node={leaf}
          tree_id={@tree_id}
          section={@section}
          compact={true}
        />
        <li :if={@node.create_child_event} class="list-none">
          <button
            type="button"
            phx-click={@node.create_child_event.event}
            phx-target={@node.create_child_event.target}
            {action_values(@node.create_child_event)}
            class="w-full flex items-center gap-1.5 px-2 py-1 rounded text-xs text-wb-text-dim hover:text-wb-text hover:bg-wb-hover"
          >
            <.icon
              :if={Map.get(@node.create_child_event, :icon)}
              name={@node.create_child_event.icon}
              class="w-3 h-3"
            />
            <span>{Map.get(@node.create_child_event, :label, "New")}</span>
          </button>
        </li>
      </ul>
    </li>
    """
  end

  defp folder_icon(%{icon: "lucide-folder"}, true), do: "lucide-folder-open"
  defp folder_icon(%{icon: "lucide-folder"}, false), do: "lucide-folder"
  defp folder_icon(%{icon: "lucide-brain"}, true), do: "lucide-brain-cog"
  defp folder_icon(%{icon: "lucide-brain"}, false), do: "lucide-brain"
  defp folder_icon(%{icon: icon}, _expanded) when is_binary(icon), do: icon
  defp folder_icon(_node, true), do: "lucide-folder-open"
  defp folder_icon(_node, false), do: "lucide-folder"

  defp folder_drop_hook(%{drop_kind: :chat}), do: "FolderDropZone"
  defp folder_drop_hook(%{drop_kind: :files}), do: "FilesDropTarget"
  # Back-compat: chat folders are draggable AND drop targets via the same hook.
  defp folder_drop_hook(%{draggable: true}), do: "FolderDropZone"
  defp folder_drop_hook(_), do: nil

  defp action_values(%{values: values}) when is_map(values) do
    Enum.into(values, %{}, fn {k, v} -> {"phx-value-#{k}", v} end)
  end

  defp action_values(_), do: %{}

  defp phx_values(%{values: values}) when is_map(values), do: action_values(%{values: values})
  defp phx_values(_), do: %{}

  # Row click event: nodes that don't set click_event default to
  # "toggle_folder" (legacy chat-folder behavior); nodes that set
  # click_event drive the row click from there. The hardcoded value-
  # folder-id is preserved as the default for back-compat.
  defp row_event(%{click_event: %{event: event}}) when is_binary(event), do: event
  defp row_event(_), do: "toggle_folder"

  defp row_phx_values(%{click_event: %{values: values}}) when is_map(values),
    do: action_values(%{values: values})

  defp row_phx_values(%{id: id}), do: %{"phx-value-folder-id" => id}
end
