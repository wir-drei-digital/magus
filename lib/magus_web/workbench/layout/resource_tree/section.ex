defmodule MagusWeb.Workbench.Layout.ResourceTree.Section do
  @moduledoc """
  A section in a workbench mode-nav tree.

  Sections compose a `ResourceTree`. Each section may have a header,
  may be collapsible, may render its nodes as date groups, and may
  declare itself as a root drop target with a particular DnD hook
  family.
  """

  defstruct key: nil,
            label: nil,
            nodes: [],
            collapsible?: false,
            collapsed?: false,
            on_toggle: nil,
            date_grouped?: false,
            empty_message: nil,
            drop_target: false,
            dnd_section_id: nil,
            dnd_kind: :none,
            target: nil
end

defmodule MagusWeb.Workbench.Layout.ResourceTree.Node do
  @moduledoc """
  A node in a section's content tree. May be a `:folder` (recursive)
  or a `:leaf`. Folders carry `children` (subfolders) and may also
  carry `conversations` (chat-style: rendered after subfolders, with
  a "+ New chat" affordance via `create_child_event`). Leaves may
  carry `subnodes` (thread-style sub-list with a left border).

  `gutter: true` reserves an empty chevron-width column on a leaf so it
  aligns with sibling folder rows (which carry an expand chevron) and
  sits one clear indent below its parent. Used by trees that toggle via
  a dedicated chevron rather than whole-row click (e.g. brain pages).
  """

  defstruct id: nil,
            kind: :leaf,
            label: nil,
            icon: nil,
            resource_type: nil,
            click_event: nil,
            chevron_event: nil,
            href: nil,
            draggable: false,
            drop_kind: :none,
            data_attrs: %{},
            children: [],
            conversations: [],
            subnodes: [],
            actions: [],
            subtitle: nil,
            badge: nil,
            editing?: false,
            editor: nil,
            create_child_event: nil,
            gutter: false

  alias __MODULE__

  @doc "Build a folder node with sensible defaults."
  def new_folder(opts) do
    struct(%Node{kind: :folder}, opts)
  end

  @doc "Build a leaf node with sensible defaults."
  def new_leaf(opts) do
    struct(%Node{kind: :leaf}, opts)
  end
end

defmodule MagusWeb.Workbench.Layout.ResourceTree.Action do
  @moduledoc """
  A hover-cluster action button on a node.
  """

  defstruct icon: nil,
            event: nil,
            values: %{},
            target: nil,
            title: nil,
            style: :default,
            confirm: nil

  def new(opts), do: struct(%__MODULE__{}, opts)
end
