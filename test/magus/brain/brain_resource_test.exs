defmodule Magus.Brain.BrainResourceTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Brain

  setup do
    user = generate(user())
    %{user: user}
  end

  describe "create_brain/2" do
    test "creates a brain with required fields", %{user: user} do
      assert {:ok, brain} =
               Brain.create_brain(%{title: "LLM Research", description: "Scaling laws and more"},
                 actor: user
               )

      assert brain.title == "LLM Research"
      assert brain.description == "Scaling laws and more"
      assert brain.user_id == user.id
      assert brain.slug != nil
      assert brain.is_archived == false
    end

    test "generates unique slug from title", %{user: user} do
      {:ok, brain1} = Brain.create_brain(%{title: "My Brain"}, actor: user)
      {:ok, brain2} = Brain.create_brain(%{title: "My Brain"}, actor: user)

      assert brain1.slug != brain2.slug
    end

    test "generates slug with lowercase and hyphens", %{user: user} do
      {:ok, brain} = Brain.create_brain(%{title: "Hello World Test"}, actor: user)

      assert brain.slug =~ ~r/^hello-world-test-[a-z0-9_-]+$/
    end

    test "requires title", %{user: user} do
      assert {:error, _} = Brain.create_brain(%{}, actor: user)
    end
  end

  describe "get_brain/2" do
    test "returns brain by id", %{user: user} do
      {:ok, brain} = Brain.create_brain(%{title: "Test Brain"}, actor: user)
      assert {:ok, found} = Brain.get_brain(brain.id, actor: user)
      assert found.id == brain.id
    end

    test "does not return other users' brains", %{user: user} do
      other_user = generate(user())
      {:ok, brain} = Brain.create_brain(%{title: "Secret Brain"}, actor: other_user)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Brain.get_brain(brain.id, actor: user)
    end
  end

  describe "list_brains/1" do
    test "lists brains for the current user", %{user: user} do
      {:ok, _} = Brain.create_brain(%{title: "Brain 1"}, actor: user)
      {:ok, _} = Brain.create_brain(%{title: "Brain 2"}, actor: user)

      assert {:ok, brains} = Brain.list_brains(actor: user)
      assert length(brains) == 2
    end

    test "does not return other users' brains", %{user: user} do
      other_user = generate(user())
      {:ok, _} = Brain.create_brain(%{title: "Other Brain"}, actor: other_user)

      assert {:ok, brains} = Brain.list_brains(actor: user)
      assert brains == []
    end

    test "does not return archived brains", %{user: user} do
      {:ok, brain} = Brain.create_brain(%{title: "To Archive"}, actor: user)
      {:ok, _archived} = Brain.archive_brain(brain, actor: user)

      assert {:ok, brains} = Brain.list_brains(actor: user)
      assert brains == []
    end

    test "returns brains sorted by updated_at descending", %{user: user} do
      {:ok, brain1} = Brain.create_brain(%{title: "First"}, actor: user)
      {:ok, _brain2} = Brain.create_brain(%{title: "Second"}, actor: user)
      # Update brain1 to make it more recent
      {:ok, _brain1_updated} = Brain.update_brain(brain1, %{title: "First Updated"}, actor: user)

      assert {:ok, [first | _]} = Brain.list_brains(actor: user)
      assert first.title == "First Updated"
    end
  end

  describe "update_brain/3" do
    test "updates brain fields", %{user: user} do
      {:ok, brain} = Brain.create_brain(%{title: "Original"}, actor: user)

      assert {:ok, updated} =
               Brain.update_brain(brain, %{title: "Updated", description: "New desc"},
                 actor: user
               )

      assert updated.title == "Updated"
      assert updated.description == "New desc"
    end
  end

  describe "archive_brain/2" do
    test "archives a brain", %{user: user} do
      {:ok, brain} = Brain.create_brain(%{title: "Test"}, actor: user)
      assert {:ok, archived} = Brain.archive_brain(brain, actor: user)
      assert archived.is_archived == true
    end
  end

  describe "destroy_brain/2" do
    test "destroys a brain", %{user: user} do
      {:ok, brain} = Brain.create_brain(%{title: "To Delete"}, actor: user)
      assert :ok = Brain.destroy_brain(brain, actor: user)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Brain.get_brain(brain.id, actor: user)
    end
  end

  describe "sub-pages" do
    setup %{user: user} do
      {:ok, brain} = Brain.create_brain(%{title: "Test Brain"}, actor: user)
      %{brain: brain}
    end

    test "creates a root page with depth 0", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{title: "Root Page"}, actor: user)

      assert page.depth == 0
      assert page.parent_page_id == nil
    end

    test "creates a sub-page with depth 1", %{user: user, brain: brain} do
      {:ok, parent} = Brain.create_page(brain.id, %{title: "Parent"}, actor: user)

      {:ok, child} =
        Brain.create_page(brain.id, %{title: "Child", parent_page_id: parent.id}, actor: user)

      assert child.depth == 1
      assert child.parent_page_id == parent.id
    end

    test "creates a sub-sub-page with depth 2", %{user: user, brain: brain} do
      {:ok, root} = Brain.create_page(brain.id, %{title: "Root"}, actor: user)

      {:ok, mid} =
        Brain.create_page(brain.id, %{title: "Mid", parent_page_id: root.id}, actor: user)

      {:ok, leaf} =
        Brain.create_page(brain.id, %{title: "Leaf", parent_page_id: mid.id}, actor: user)

      assert leaf.depth == 2
    end

    test "allows arbitrarily deep nesting (cap removed in Phase C7)", %{user: user, brain: brain} do
      # Walk down 8 levels — far beyond any previous cap. Each step's
      # depth attribute must increment by 1.
      {:ok, root} = Brain.create_page(brain.id, %{title: "L0"}, actor: user)

      pages =
        Enum.reduce(1..7, [root], fn level, [parent | _] = acc ->
          {:ok, child} =
            Brain.create_page(
              brain.id,
              %{title: "L#{level}", parent_page_id: parent.id},
              actor: user
            )

          [child | acc]
        end)

      depths = pages |> Enum.reverse() |> Enum.map(& &1.depth)
      assert depths == Enum.to_list(0..7)
    end

    test "list_root_pages returns only root pages", %{user: user, brain: brain} do
      {:ok, root1} = Brain.create_page(brain.id, %{title: "Root 1"}, actor: user)
      {:ok, _root2} = Brain.create_page(brain.id, %{title: "Root 2"}, actor: user)

      {:ok, _child} =
        Brain.create_page(brain.id, %{title: "Child", parent_page_id: root1.id}, actor: user)

      {:ok, roots} = Brain.list_root_pages(brain.id, actor: user)

      assert length(roots) == 2
      assert Enum.all?(roots, fn p -> p.parent_page_id == nil end)
    end

    test "list_children_pages returns direct children", %{user: user, brain: brain} do
      {:ok, parent} = Brain.create_page(brain.id, %{title: "Parent"}, actor: user)

      {:ok, child1} =
        Brain.create_page(brain.id, %{title: "Child 1", parent_page_id: parent.id}, actor: user)

      {:ok, child2} =
        Brain.create_page(brain.id, %{title: "Child 2", parent_page_id: parent.id}, actor: user)

      {:ok, _grandchild} =
        Brain.create_page(brain.id, %{title: "Grandchild", parent_page_id: child1.id},
          actor: user
        )

      {:ok, children} = Brain.list_children_pages(parent.id, actor: user)

      assert length(children) == 2
      child_ids = Enum.map(children, & &1.id)
      assert child1.id in child_ids
      assert child2.id in child_ids
    end

    test "cascade deletes children when parent is deleted", %{user: user, brain: brain} do
      {:ok, parent} = Brain.create_page(brain.id, %{title: "Parent"}, actor: user)

      {:ok, child} =
        Brain.create_page(brain.id, %{title: "Child", parent_page_id: parent.id}, actor: user)

      {:ok, grandchild} =
        Brain.create_page(brain.id, %{title: "Grandchild", parent_page_id: child.id}, actor: user)

      assert :ok = Brain.destroy_page(parent, actor: user)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Brain.get_page(child.id, actor: user)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Brain.get_page(grandchild.id, actor: user)
    end

    test "siblings are positioned independently per parent", %{user: user, brain: brain} do
      {:ok, parent1} = Brain.create_page(brain.id, %{title: "Parent 1"}, actor: user)
      {:ok, parent2} = Brain.create_page(brain.id, %{title: "Parent 2"}, actor: user)

      {:ok, child_a} =
        Brain.create_page(brain.id, %{title: "Child A", parent_page_id: parent1.id}, actor: user)

      {:ok, child_b} =
        Brain.create_page(brain.id, %{title: "Child B", parent_page_id: parent2.id}, actor: user)

      assert child_a.position == child_b.position
    end
  end

  describe "move_to_parent" do
    setup %{user: user} do
      {:ok, brain} = Brain.create_brain(%{title: "Test Brain"}, actor: user)
      %{brain: brain}
    end

    test "moves a root page under a parent", %{user: user, brain: brain} do
      {:ok, parent} = Brain.create_page(brain.id, %{title: "Parent"}, actor: user)
      {:ok, child} = Brain.create_page(brain.id, %{title: "Child"}, actor: user)

      assert child.depth == 0
      assert child.parent_page_id == nil

      {:ok, moved} = Brain.move_page_to_parent(child, %{parent_page_id: parent.id}, actor: user)

      assert moved.depth == 1
      assert moved.parent_page_id == parent.id
    end

    test "moves a sub-page to root", %{user: user, brain: brain} do
      {:ok, parent} = Brain.create_page(brain.id, %{title: "Parent"}, actor: user)

      {:ok, child} =
        Brain.create_page(brain.id, %{title: "Child", parent_page_id: parent.id}, actor: user)

      assert child.depth == 1

      {:ok, moved} = Brain.move_page_to_parent(child, %{parent_page_id: nil}, actor: user)

      assert moved.depth == 0
      assert moved.parent_page_id == nil
    end

    test "rejects moving a page under itself", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{title: "Page"}, actor: user)

      assert {:error, _} =
               Brain.move_page_to_parent(page, %{parent_page_id: page.id}, actor: user)
    end

    test "rejects circular reference", %{user: user, brain: brain} do
      {:ok, parent} = Brain.create_page(brain.id, %{title: "Parent"}, actor: user)

      {:ok, child} =
        Brain.create_page(brain.id, %{title: "Child", parent_page_id: parent.id}, actor: user)

      assert {:error, _} =
               Brain.move_page_to_parent(parent, %{parent_page_id: child.id}, actor: user)
    end

    test "allows moves that previously exceeded the depth cap", %{user: user, brain: brain} do
      # Create a chain: root -> mid (depth 0 -> 1)
      {:ok, root} = Brain.create_page(brain.id, %{title: "Root"}, actor: user)

      {:ok, mid} =
        Brain.create_page(brain.id, %{title: "Mid", parent_page_id: root.id}, actor: user)

      # Separate branch with a child: branch (depth 0) -> branch_child (depth 1)
      {:ok, branch} = Brain.create_page(brain.id, %{title: "Branch"}, actor: user)

      {:ok, _branch_child} =
        Brain.create_page(brain.id, %{title: "Branch Child", parent_page_id: branch.id},
          actor: user
        )

      # Phase A removed the depth cap; this move would have failed before, now succeeds.
      assert {:ok, moved} =
               Brain.move_page_to_parent(branch, %{parent_page_id: mid.id}, actor: user)

      assert moved.depth == 2
    end

    test "updates descendant depths on move", %{user: user, brain: brain} do
      {:ok, parent} = Brain.create_page(brain.id, %{title: "Parent"}, actor: user)
      {:ok, branch} = Brain.create_page(brain.id, %{title: "Branch"}, actor: user)

      {:ok, leaf} =
        Brain.create_page(brain.id, %{title: "Leaf", parent_page_id: branch.id}, actor: user)

      assert branch.depth == 0
      assert leaf.depth == 1

      {:ok, _moved} =
        Brain.move_page_to_parent(branch, %{parent_page_id: parent.id}, actor: user)

      # Reload the leaf to check its depth was updated
      {:ok, reloaded_leaf} = Brain.get_page(leaf.id, actor: user)
      assert reloaded_leaf.depth == 2
    end
  end
end
