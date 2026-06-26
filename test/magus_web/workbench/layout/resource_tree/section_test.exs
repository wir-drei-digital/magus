defmodule MagusWeb.Workbench.Layout.ResourceTree.SectionTest do
  use ExUnit.Case, async: true

  alias MagusWeb.Workbench.Layout.ResourceTree.{Section, Node, Action}

  describe "Section" do
    test "default fields" do
      s = %Section{key: :personal, nodes: []}
      assert s.label == nil
      assert s.collapsible? == false
      assert s.collapsed? == false
      assert s.date_grouped? == false
      assert s.empty_message == nil
      assert s.drop_target == false
      assert s.dnd_kind == :none
    end
  end

  describe "Node.new_folder/1 and Node.new_leaf/1" do
    test "new_folder defaults" do
      n =
        Node.new_folder(id: "f1", label: "Drafts", icon: "lucide-folder", resource_type: :folder)

      assert n.kind == :folder
      assert n.id == "f1"
      assert n.children == []
      assert n.actions == []
      assert n.draggable == false
    end

    test "new_leaf defaults" do
      n =
        Node.new_leaf(
          id: "c1",
          label: "Hello",
          icon: "lucide-messages-square",
          resource_type: :conversation
        )

      assert n.kind == :leaf
      assert n.actions == []
      assert n.subnodes == []
    end
  end

  describe "Action.new/1" do
    test "default style and confirm" do
      a =
        Action.new(
          icon: "lucide-trash-2",
          event: "delete",
          values: %{id: "1"},
          target: :myself,
          title: "Delete"
        )

      assert a.style == :default
      assert a.confirm == nil
    end
  end
end
