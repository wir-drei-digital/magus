defmodule MagusWeb.Workbench.Layout.ResourceTree do
  @moduledoc """
  Generic LiveComponent that renders a list of `%Section{}` nodes
  with consistent chrome (section headers, empty states, recursive
  folders, leaf rows, DnD wiring, and per-node action clusters).

  The component owns no state. Events bubble to the LiveComponent /
  LiveView that supplied each `click_event` / `action.target`. Mode
  navs build the section list from their own `Data` shaper and mount
  this component.
  """
  use MagusWeb, :live_component

  import MagusWeb.Workbench.Layout.ResourceTree.SectionHeader
  import MagusWeb.Workbench.Layout.ResourceTree.FolderNode
  import MagusWeb.Workbench.Layout.ResourceTree.LeafNode

  # Expected assigns (passed via <.live_component ...>):
  #   :sections          (list, required)
  #   :expanded_folders  (map, default %{})
  #   :auto_expanded_ids (MapSet | nil, default nil)
  #   :editing_id        (any, default nil)

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <nav class="flex flex-col h-full overflow-y-auto wb-no-scrollbar" aria-label="Resources">
      <.render_section
        :for={section <- @sections}
        section={section}
        tree_id={@id}
        expanded_folders={@expanded_folders}
        auto_expanded_ids={@auto_expanded_ids || MapSet.new()}
        editing_id={@editing_id}
      />
    </nav>
    """
  end

  attr :section, :map, required: true
  attr :tree_id, :string, required: true
  attr :expanded_folders, :map, required: true
  attr :auto_expanded_ids, :any, required: true
  attr :editing_id, :any, default: nil

  defp render_section(assigns) do
    ~H"""
    <section class="flex flex-col mt-2">
      <.section_header
        :if={@section.label}
        label={@section.label}
        collapsible?={@section.collapsible?}
        collapsed?={@section.collapsed?}
        on_toggle={@section.on_toggle}
        target={@section.target}
      />

      <ul
        :if={!@section.collapsible? or !@section.collapsed?}
        id={section_id(@section, @tree_id)}
        data-section={@section.dnd_section_id || ""}
        data-folder-id=""
        data-resource-type={section_resource_type(@section)}
        phx-hook={drop_hook(@section)}
        phx-target={@section.target}
        class="px-2 space-y-0.5 min-h-[8px]"
      >
        <.empty_state
          :if={@section.empty_message && section_empty?(@section)}
          message={@section.empty_message}
        />

        <%= cond do %>
          <% @section.date_grouped? -> %>
            <%= for {label, group_nodes} <- @section.nodes do %>
              <li
                :if={label != ""}
                class="list-none px-3 pt-3 pb-1 text-[10px] uppercase tracking-wider text-wb-text-dim"
              >
                {label}
              </li>
              <.render_node
                :for={node <- group_nodes}
                node={node}
                tree_id={@tree_id}
                expanded_folders={@expanded_folders}
                auto_expanded_ids={@auto_expanded_ids}
                editing_id={@editing_id}
                section={@section.dnd_section_id || ""}
                section_key={@section.key}
              />
            <% end %>
          <% true -> %>
            <.render_node
              :for={node <- @section.nodes}
              node={node}
              tree_id={@tree_id}
              expanded_folders={@expanded_folders}
              auto_expanded_ids={@auto_expanded_ids}
              editing_id={@editing_id}
              section={@section.dnd_section_id || ""}
              section_key={@section.key}
            />
        <% end %>
      </ul>
    </section>
    """
  end

  attr :node, :map, required: true
  attr :tree_id, :string, required: true
  attr :expanded_folders, :map, required: true
  attr :auto_expanded_ids, :any, required: true
  attr :editing_id, :any, default: nil
  attr :section, :string, default: ""
  attr :section_key, :any, default: nil

  defp render_node(assigns) do
    ~H"""
    <%= case @node.kind do %>
      <% :folder -> %>
        <.folder_node
          node={@node}
          tree_id={@tree_id}
          expanded_folders={@expanded_folders}
          auto_expanded_ids={@auto_expanded_ids}
          section={@section}
          editing_id={@editing_id}
        />
      <% :leaf -> %>
        <.leaf_node
          node={@node}
          tree_id={@tree_id}
          section={@section}
          section_key={@section_key}
          compact={false}
        />
    <% end %>
    """
  end

  defp section_id(%{key: key}, tree_id), do: "#{tree_id}-section-#{key}"

  defp section_resource_type(%{nodes: nodes}) do
    case List.first(nodes) do
      %{resource_type: type} when not is_nil(type) -> to_string(type)
      _ -> ""
    end
  end

  defp drop_hook(%{drop_target: true, dnd_kind: :chat}), do: "DroppableFolder"
  defp drop_hook(%{drop_target: true, dnd_kind: :files}), do: "FilesDropTarget"
  defp drop_hook(_), do: nil

  defp section_empty?(%{date_grouped?: true, nodes: nodes}), do: nodes == []
  defp section_empty?(%{nodes: nodes}), do: nodes == []
end
