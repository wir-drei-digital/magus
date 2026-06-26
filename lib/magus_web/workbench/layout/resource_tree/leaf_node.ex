defmodule MagusWeb.Workbench.Layout.ResourceTree.LeafNode do
  @moduledoc """
  Renders a single leaf node row plus its optional subnodes (threads-
  style sub-list rendered with a left border). Generic across resource
  types — receives a `%Node{}` and a section context.
  """
  use MagusWeb, :html

  attr :node, :map, required: true, doc: "%Node{kind: :leaf}"
  attr :tree_id, :string, required: true, doc: "owning tree's @id, used to namespace DOM ids"
  attr :section, :string, required: true, doc: "shared | personal | mode-specific"

  attr :section_key, :any,
    default: nil,
    doc:
      "Section.key — namespaces the DOM id when a node appears in multiple sections (e.g. :favorites)"

  attr :compact, :boolean, default: false, doc: "true when nested under a folder"

  def leaf_node(assigns) do
    assigns = assign(assigns, :leaf_dom_id, leaf_dom_id(assigns))

    ~H"""
    <li
      id={@leaf_dom_id}
      data-resource-type={to_string(@node.resource_type)}
      data-section={@section}
      data-resource-id={@node.id}
      draggable={if @node.draggable, do: "true", else: "false"}
      phx-hook={drag_hook(@node)}
      class="list-none"
      {data_attrs(@node.data_attrs)}
    >
      <div class="group flex items-center gap-1">
        <span :if={@node.gutter} class="w-4 shrink-0" aria-hidden="true"></span>
        <.row_button node={@node} compact={@compact} />
        <.action_cluster
          :if={@node.actions != []}
          actions={@node.actions}
          menu_id={"#{@leaf_dom_id}-actions"}
        />
      </div>

      <ul
        :if={@node.subnodes != []}
        class="ml-4 border-l border-wb-border-strong pl-2 mt-0.5 space-y-0.5"
      >
        <li :for={sub <- @node.subnodes} class="list-none">
          <.subnode_button node={sub} />
        </li>
      </ul>
    </li>
    """
  end

  defp row_button(assigns) do
    base_class =
      "flex-1 flex items-center gap-2 px-2 py-1.5 rounded-md hover:bg-wb-hover text-wb-text-secondary hover:text-wb-text transition-colors min-w-0"

    assigns = assign(assigns, :base_class, base_class)

    ~H"""
    <%= cond do %>
      <% @node.click_event -> %>
        <button
          type="button"
          phx-click={@node.click_event.event}
          phx-target={Map.get(@node.click_event, :target)}
          {click_values(@node.click_event)}
          class={@base_class}
        >
          <.row_inner node={@node} compact={@compact} />
        </button>
      <% @node.href -> %>
        <.link navigate={@node.href} class={@base_class}>
          <.row_inner node={@node} compact={@compact} />
        </.link>
      <% true -> %>
        <div class={@base_class}>
          <.row_inner node={@node} compact={@compact} />
        </div>
    <% end %>
    """
  end

  defp row_inner(assigns) do
    ~H"""
    <.icon
      :if={@node.icon}
      name={@node.icon}
      class="w-3.5 h-3.5 shrink-0"
    />
    <span class="flex-1 text-left text-sm truncate">{@node.label}</span>
    <span
      :if={@node.badge}
      class="ml-1 text-[10px] uppercase tracking-wide bg-base-300 text-wb-text-dim px-1 rounded"
    >
      {@node.badge}
    </span>
    <span :if={!@compact and @node.subtitle} class="text-[10px] text-wb-text-dim">
      {@node.subtitle}
    </span>
    """
  end

  attr :actions, :list, required: true
  attr :menu_id, :string, required: true

  defp action_cluster(assigns) do
    ~H"""
    <div class="flex items-center shrink-0">
      <%!-- Desktop: hover-revealed individual action buttons --%>
      <div data-actions="row" class="hidden md:flex items-center">
        <button
          :for={action <- @actions}
          type="button"
          phx-click={action.event}
          phx-target={action.target}
          {action_values(action)}
          data-confirm={action.confirm}
          class={[
            "p-1 rounded hover:bg-wb-hover",
            action.style == :active && "text-warning",
            action.style != :active && "opacity-0 group-hover:opacity-100 text-wb-text-dim",
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
        id={@menu_id}
        wrapper_class="relative inline-block md:hidden"
        trigger_class="p-1 rounded hover:bg-wb-hover text-wb-text-dim"
        class="w-44"
      >
        <:trigger>
          <.icon name="lucide-more-vertical" class="w-3.5 h-3.5" />
        </:trigger>
        <:item :for={action <- @actions}>
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
    """
  end

  defp subnode_button(assigns) do
    ~H"""
    <%= cond do %>
      <% @node.click_event -> %>
        <button
          type="button"
          phx-click={@node.click_event.event}
          phx-target={Map.get(@node.click_event, :target)}
          {click_values(@node.click_event)}
          class="w-full flex items-center gap-1.5 px-2 py-1 rounded hover:bg-wb-hover text-wb-text-dim hover:text-wb-text text-xs"
        >
          <.icon :if={@node.icon} name={@node.icon} class="w-3 h-3 shrink-0" />
          <span class="truncate">{@node.label}</span>
        </button>
      <% @node.href -> %>
        <.link
          navigate={@node.href}
          class="w-full flex items-center gap-1.5 px-2 py-1 rounded hover:bg-wb-hover text-wb-text-dim hover:text-wb-text text-xs"
        >
          <.icon :if={@node.icon} name={@node.icon} class="w-3 h-3 shrink-0" />
          <span class="truncate">{@node.label}</span>
        </.link>
      <% true -> %>
        <span class="text-xs text-wb-text-dim px-2 py-1">{@node.label}</span>
    <% end %>
    """
  end

  defp click_values(%{values: values}) when is_map(values) do
    Enum.into(values, %{}, fn {k, v} -> {"phx-value-#{k}", v} end)
  end

  defp click_values(_), do: %{}

  defp action_values(%{values: values}) when is_map(values) do
    Enum.into(values, %{}, fn {k, v} -> {"phx-value-#{k}", v} end)
  end

  defp action_values(_), do: %{}

  defp data_attrs(map) when is_map(map) do
    Enum.into(map, %{}, fn {k, v} -> {"data-#{k}", v} end)
  end

  defp data_attrs(_), do: %{}

  # File leaves use a dedicated `DraggableFile` hook so drops onto the brain
  # editor can be told apart from conversation/message drags. Other draggable
  # leaves (conversations) keep the existing hook.
  defp drag_hook(%{draggable: true, resource_type: :file}), do: "DraggableFile"
  defp drag_hook(%{draggable: true}), do: "DraggableConversation"
  defp drag_hook(_), do: nil

  # Namespace the DOM id with the section key when a node may also appear in
  # another section (e.g. a personal conversation surfaced under :favorites).
  # Without this, the same conversation rendered in two sections produces
  # duplicate <li id="..."> elements and LiveView DOM patching falls over —
  # which manifested as the nav-list "favorite" star doing nothing visually.
  defp leaf_dom_id(%{tree_id: tree_id, node: %{id: id}, section_key: :favorites}),
    do: "#{tree_id}-favorites-leaf-#{id}"

  defp leaf_dom_id(%{tree_id: tree_id, node: %{id: id}}),
    do: "#{tree_id}-leaf-#{id}"
end
