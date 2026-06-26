defmodule MagusWeb.Workbench.Modes.BrainModeNav.DataTest do
  use Magus.ResourceCase, async: true

  alias MagusWeb.Workbench.Modes.BrainModeNav.Data
  alias MagusWeb.Workbench.Layout.ResourceTree.Section
  alias MagusWeb.Workbench.WorkspaceShare
  alias Magus.Workspaces

  defp setup_workspace do
    user = generate(user())
    ensure_workspace_plan(user)

    {:ok, workspace} =
      Workspaces.create_workspace(
        %{name: "Brain WS", slug: "brain-ws-#{System.unique_integer([:positive])}"},
        actor: user
      )

    %{user: user, workspace: workspace}
  end

  describe "load_sections/1 in personal mode" do
    test "returns a personal section with brains as folder nodes" do
      user = generate(user())
      {:ok, brain} = Magus.Brain.create_brain(%{title: "My brain"}, actor: user)

      sections =
        Data.load_sections(%{
          user: user,
          workspace_id: nil,
          search_query: "",
          expanded_brain_ids: MapSet.new(),
          tree_target: "#brain-tree"
        })

      [%Section{key: :personal, nodes: nodes}] = sections
      assert Enum.any?(nodes, &(&1.id == brain.id and &1.kind == :folder))
    end

    test "personal brain row exposes only an edit action (no share toggle)" do
      user = generate(user())
      {:ok, _brain} = Magus.Brain.create_brain(%{title: "My brain"}, actor: user)

      sections =
        Data.load_sections(%{
          user: user,
          workspace_id: nil,
          search_query: "",
          expanded_brain_ids: MapSet.new(),
          tree_target: self()
        })

      [%Section{nodes: [brain_node]}] = sections

      assert [%{event: "edit_brain"}] = brain_node.actions
    end
  end

  describe "load_sections/1 in workspace mode — share action" do
    test "unshared workspace brain row exposes a share + edit action" do
      %{user: user, workspace: workspace} = setup_workspace()

      {:ok, _brain} =
        Magus.Brain.create_brain(%{title: "WS brain", workspace_id: workspace.id}, actor: user)

      sections =
        Data.load_sections(%{
          user: user,
          workspace_id: workspace.id,
          search_query: "",
          expanded_brain_ids: MapSet.new(),
          tree_target: self()
        })

      personal = Enum.find(sections, &(&1.key == :personal))
      assert [brain_node] = personal.nodes
      assert [share, edit] = brain_node.actions
      assert share.event == "share_brain"
      assert share.icon == "lucide-users"
      assert edit.event == "edit_brain"
    end

    test "shared workspace brain row exposes an unshare + edit action" do
      %{user: user, workspace: workspace} = setup_workspace()

      {:ok, brain} =
        Magus.Brain.create_brain(%{title: "WS brain", workspace_id: workspace.id}, actor: user)

      {:ok, _} = WorkspaceShare.share(:brain, brain, user)

      sections =
        Data.load_sections(%{
          user: user,
          workspace_id: workspace.id,
          search_query: "",
          expanded_brain_ids: MapSet.new(),
          tree_target: self()
        })

      shared = Enum.find(sections, &(&1.key == :shared))
      assert [brain_node] = shared.nodes
      assert [unshare, edit] = brain_node.actions
      assert unshare.event == "unshare_brain"
      assert unshare.icon == "lucide-user-check"
      assert edit.event == "edit_brain"
    end
  end

  describe "load_sections/1 — page tree" do
    test "renders root, child, and grandchild pages when brain is expanded" do
      user = generate(user())
      {:ok, brain} = Magus.Brain.create_brain(%{title: "Tree"}, actor: user)
      {:ok, root} = Magus.Brain.create_page(brain.id, %{title: "Root"}, actor: user)

      {:ok, child} =
        Magus.Brain.create_page(brain.id, %{title: "Child", parent_page_id: root.id}, actor: user)

      {:ok, grandchild} =
        Magus.Brain.create_page(brain.id, %{title: "Grandchild", parent_page_id: child.id},
          actor: user
        )

      sections =
        Data.load_sections(%{
          user: user,
          workspace_id: nil,
          search_query: "",
          expanded_brain_ids: MapSet.new([brain.id]),
          tree_target: self()
        })

      [%Section{nodes: [brain_node]}] = sections

      # Root has a child → folder, in brain's :children slot.
      assert [root_node] = brain_node.children
      assert root_node.id == root.id
      assert root_node.kind == :folder
      assert brain_node.conversations == []

      # Child has a grandchild → folder, in root's :children.
      assert [child_node] = root_node.children
      assert child_node.id == child.id
      assert child_node.kind == :folder
      assert root_node.conversations == []

      # Grandchild has no children → leaf, in child's :conversations.
      assert child_node.children == []
      assert [grandchild_node] = child_node.conversations
      assert grandchild_node.id == grandchild.id
      assert grandchild_node.kind == :leaf
    end

    test "page folder row click opens the page; chevron toggles its children" do
      user = generate(user())
      {:ok, brain} = Magus.Brain.create_brain(%{title: "Open Action"}, actor: user)
      {:ok, parent} = Magus.Brain.create_page(brain.id, %{title: "Parent"}, actor: user)

      {:ok, _child} =
        Magus.Brain.create_page(brain.id, %{title: "Child", parent_page_id: parent.id},
          actor: user
        )

      sections =
        Data.load_sections(%{
          user: user,
          workspace_id: nil,
          search_query: "",
          expanded_brain_ids: MapSet.new([brain.id]),
          tree_target: self()
        })

      [%Section{nodes: [brain_node]}] = sections
      [parent_node] = brain_node.children

      # Row click opens the page (like a leaf).
      assert parent_node.click_event.event == "open_tab"
      assert parent_node.click_event.values["type"] == "brain_page"
      assert parent_node.click_event.values["id"] == parent.id

      # A separate chevron toggles expand/collapse so a parent page can
      # still be opened directly from the nav.
      assert parent_node.chevron_event.event == "toggle_folder"
      assert parent_node.chevron_event.values["folder-id"] == parent.id

      # No extra "Open page" hover action — the row click is the primary
      # affordance now.
      refute Enum.any?(parent_node.actions, &(&1.event == "open_tab"))
    end

    test "brain folder has no chevron_event — whole row toggles, as before" do
      user = generate(user())
      {:ok, brain} = Magus.Brain.create_brain(%{title: "Brain"}, actor: user)
      {:ok, _page} = Magus.Brain.create_page(brain.id, %{title: "P"}, actor: user)

      sections =
        Data.load_sections(%{
          user: user,
          workspace_id: nil,
          search_query: "",
          expanded_brain_ids: MapSet.new([brain.id]),
          tree_target: self()
        })

      [%Section{nodes: [brain_node]}] = sections

      assert is_nil(brain_node.chevron_event)
      assert brain_node.click_event.event == "toggle_folder"
    end

    test "leaf page exposes a row click_event that opens the tab" do
      user = generate(user())
      {:ok, brain} = Magus.Brain.create_brain(%{title: "Leaf"}, actor: user)
      {:ok, lone} = Magus.Brain.create_page(brain.id, %{title: "Lone"}, actor: user)

      sections =
        Data.load_sections(%{
          user: user,
          workspace_id: nil,
          search_query: "",
          expanded_brain_ids: MapSet.new([brain.id]),
          tree_target: self()
        })

      [%Section{nodes: [brain_node]}] = sections
      assert [leaf] = brain_node.conversations
      assert leaf.id == lone.id
      assert leaf.click_event.event == "open_tab"
      assert leaf.click_event.values["id"] == lone.id

      # Leaf pages reserve the chevron-width gutter so they line up with
      # sibling pages-with-subpages (which carry a chevron) and indent one
      # clear level below their parent.
      assert leaf.gutter == true
    end
  end

  describe "trash action on page nodes" do
    test "each page node includes a trash action with a confirm prompt" do
      user = generate(user())
      {:ok, brain} = Magus.Brain.create_brain(%{title: "B"}, actor: user)
      {:ok, _page} = Magus.Brain.create_page(brain.id, %{title: "P"}, actor: user)

      sections =
        Data.load_sections(%{
          user: user,
          workspace_id: nil,
          search_query: "",
          expanded_brain_ids: MapSet.new([brain.id]),
          tree_target: self()
        })

      [%Section{nodes: [brain_node]}] = sections
      [page_node] = brain_node.conversations

      trash_action =
        Enum.find(page_node.actions, fn a ->
          a.event == "trash_page" and a.icon == "lucide-trash-2"
        end)

      assert trash_action
      assert trash_action.style == :danger
      assert is_binary(trash_action.confirm)
      assert trash_action.confirm =~ "sub-pages"
    end
  end
end
