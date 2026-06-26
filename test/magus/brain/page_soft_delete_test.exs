defmodule Magus.Brain.PageSoftDeleteTest do
  use Magus.ResourceCase, async: true

  alias Magus.Brain

  import Ecto.Query, only: [from: 2]
  require Ash.Query

  defp setup_brain(user \\ nil) do
    user = user || generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "B"}, actor: user)
    %{user: user, brain: brain}
  end

  defp reload_including_trashed(page) do
    Magus.Brain.Page
    |> Ash.Query.for_read(:read_including_trashed)
    |> Ash.Query.filter(id == ^page.id)
    |> Ash.read_one!(authorize?: false)
  end

  describe "soft_delete" do
    test "stamps deleted_at on the page" do
      %{user: user, brain: brain} = setup_brain()
      {:ok, page} = Brain.create_page(brain.id, %{title: "Doomed"}, actor: user)

      assert {:ok, deleted} = Brain.soft_delete_page(page, actor: user)
      assert deleted.deleted_at
    end

    test "is idempotent: re-running on a trashed page preserves the original timestamp" do
      %{user: user, brain: brain} = setup_brain()
      {:ok, page} = Brain.create_page(brain.id, %{title: "X"}, actor: user)
      {:ok, first} = Brain.soft_delete_page(page, actor: user)

      # Simulate a UI double-click or agent retry.
      {:ok, second} = Brain.soft_delete_page(reload_including_trashed(first), actor: user)

      assert DateTime.compare(first.deleted_at, second.deleted_at) == :eq
    end

    test "does NOT stamp descendants (they are hidden by the ancestor-trashed read filter)" do
      %{user: user, brain: brain} = setup_brain()
      {:ok, root} = Brain.create_page(brain.id, %{title: "Root"}, actor: user)

      {:ok, child} =
        Brain.create_page(brain.id, %{title: "Child", parent_page_id: root.id}, actor: user)

      {:ok, grand} =
        Brain.create_page(brain.id, %{title: "Grand", parent_page_id: child.id}, actor: user)

      assert {:ok, _} = Brain.soft_delete_page(root, actor: user)

      assert reload_including_trashed(root).deleted_at
      assert is_nil(reload_including_trashed(child).deleted_at)
      assert is_nil(reload_including_trashed(grand).deleted_at)

      # Descendants are invisible to active reads because their ancestor is trashed.
      assert {:error, _} = Brain.get_page(child.id, actor: user)
      assert {:error, _} = Brain.get_page(grand.id, actor: user)
    end
  end

  describe "restore" do
    test "restoring a root makes the whole subtree visible again" do
      %{user: user, brain: brain} = setup_brain()
      {:ok, root} = Brain.create_page(brain.id, %{title: "Root"}, actor: user)

      {:ok, child} =
        Brain.create_page(brain.id, %{title: "Child", parent_page_id: root.id}, actor: user)

      {:ok, root} = Brain.soft_delete_page(root, actor: user)

      assert {:ok, restored} = Brain.restore_page(root, actor: user)
      assert is_nil(restored.deleted_at)

      # Child was never stamped; restoring root makes it visible because the
      # ancestor-trashed filter now passes for it.
      assert {:ok, _} = Brain.get_page(child.id, actor: user)
    end

    test "refuses to restore a page whose ancestor is still trashed" do
      %{user: user, brain: brain} = setup_brain()
      {:ok, root} = Brain.create_page(brain.id, %{title: "Root"}, actor: user)

      {:ok, child} =
        Brain.create_page(brain.id, %{title: "Child", parent_page_id: root.id}, actor: user)

      {:ok, _} = Brain.soft_delete_page(root, actor: user)

      # Independently trash the child (it's hidden from get_page, so we read
      # via the internal action).
      child_active = reload_including_trashed(child)
      {:ok, child_trashed} = Brain.soft_delete_page(child_active, actor: user)

      assert {:error, _} = Brain.restore_page(child_trashed, actor: user)
    end

    test "refuses to restore a page that is not trashed" do
      %{user: user, brain: brain} = setup_brain()
      {:ok, page} = Brain.create_page(brain.id, %{title: "Active"}, actor: user)

      assert {:error, _} = Brain.restore_page(page, actor: user)
    end
  end

  describe "read filtering" do
    test "trashed pages and their descendants are excluded from all active reads" do
      %{user: user, brain: brain} = setup_brain()
      {:ok, parent} = Brain.create_page(brain.id, %{title: "Visible"}, actor: user)

      {:ok, child} =
        Brain.create_page(brain.id, %{title: "Sub", parent_page_id: parent.id}, actor: user)

      {:ok, _} = Brain.soft_delete_page(parent, actor: user)

      assert {:error, _} = Brain.get_page(parent.id, actor: user)
      assert {:error, _} = Brain.get_page(child.id, actor: user)
      assert {:ok, []} = Brain.list_pages(brain.id, actor: user)
      assert {:ok, []} = Brain.list_root_pages(brain.id, actor: user)
      assert {:ok, []} = Brain.list_children_pages(parent.id, actor: user)
      assert {:ok, []} = Brain.find_page_by_title(brain.id, "Visible", actor: user)
      assert {:ok, []} = Brain.find_page_by_title(brain.id, "Sub", actor: user)
    end

    test "re-creating a page with the same slug after trashing the original succeeds" do
      %{user: user, brain: brain} = setup_brain()
      {:ok, original} = Brain.create_page(brain.id, %{title: "Reusable"}, actor: user)
      {:ok, _} = Brain.soft_delete_page(original, actor: user)

      assert {:ok, _fresh} = Brain.create_page(brain.id, %{title: "Reusable"}, actor: user)
    end

    test "body survives a soft-delete/restore round-trip" do
      %{user: user, brain: brain} = setup_brain()
      {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)

      {:ok, _} =
        Brain.update_page_body(
          page,
          %{body: "hello", base_version: page.lock_version},
          actor: user
        )

      {:ok, trashed} = Brain.soft_delete_page(page, actor: user)
      {:ok, _} = Brain.restore_page(trashed, actor: user)

      {:ok, restored} = Brain.get_page(page.id, actor: user)
      assert restored.body == "hello"
    end
  end

  describe "trashed read" do
    test "lists deletion roots only (descendants hidden under trashed ancestor)" do
      %{user: user, brain: brain} = setup_brain()
      {:ok, root} = Brain.create_page(brain.id, %{title: "Top"}, actor: user)

      {:ok, _child} =
        Brain.create_page(brain.id, %{title: "Mid", parent_page_id: root.id}, actor: user)

      {:ok, _} = Brain.soft_delete_page(root, actor: user)

      assert {:ok, [trashed]} = Brain.list_trashed_pages(nil, actor: user)
      assert trashed.id == root.id
    end

    test "a child independently trashed before its parent appears under the parent in trash, then surfaces as its own root after the parent is restored" do
      %{user: user, brain: brain} = setup_brain()
      {:ok, root} = Brain.create_page(brain.id, %{title: "Root"}, actor: user)

      {:ok, child} =
        Brain.create_page(brain.id, %{title: "Child", parent_page_id: root.id}, actor: user)

      # Trash child first, then root. Both have deleted_at set.
      {:ok, child} = Brain.soft_delete_page(child, actor: user)
      {:ok, root} = Brain.soft_delete_page(root, actor: user)

      # The trash listing shows only the outermost (root) because the child
      # is under a trashed ancestor.
      {:ok, list} = Brain.list_trashed_pages(nil, actor: user)
      assert Enum.map(list, & &1.id) == [root.id]

      # Restore root. Child is still trashed AND is now a deletion root
      # in its own right (its ancestor is no longer trashed).
      {:ok, _} = Brain.restore_page(root, actor: user)
      {:ok, list_after} = Brain.list_trashed_pages(nil, actor: user)
      assert Enum.map(list_after, & &1.id) == [child.id]
    end

    test "scopes to workspace via the parent brain" do
      creator = generate(user())
      ensure_workspace_plan(creator)

      {:ok, ws} =
        Magus.Workspaces.create_workspace(
          %{name: "T", slug: "t-trash-#{System.unique_integer([:positive])}"},
          actor: creator
        )

      {:ok, personal_brain} = Brain.create_brain(%{title: "Personal"}, actor: creator)
      {:ok, ws_brain} = Brain.create_brain(%{title: "WS", workspace_id: ws.id}, actor: creator)

      {:ok, p_page} = Brain.create_page(personal_brain.id, %{title: "P"}, actor: creator)
      {:ok, w_page} = Brain.create_page(ws_brain.id, %{title: "W"}, actor: creator)

      Brain.soft_delete_page!(p_page, actor: creator)
      Brain.soft_delete_page!(w_page, actor: creator)

      {:ok, personal_list} = Brain.list_trashed_pages(nil, actor: creator)
      {:ok, ws_list} = Brain.list_trashed_pages(ws.id, actor: creator)

      assert Enum.map(personal_list, & &1.id) == [p_page.id]
      assert Enum.map(ws_list, & &1.id) == [w_page.id]
    end
  end

  describe "trashed_for_cleanup" do
    test "returns pages soft-deleted more than 30 days ago" do
      %{user: user, brain: brain} = setup_brain()
      {:ok, fresh} = Brain.create_page(brain.id, %{title: "Fresh"}, actor: user)
      {:ok, ancient} = Brain.create_page(brain.id, %{title: "Ancient"}, actor: user)

      Brain.soft_delete_page!(fresh, actor: user)
      Brain.soft_delete_page!(ancient, actor: user)

      # Back-date "ancient" 31 days into the past via a direct repo update —
      # the Ash :soft_delete action only stamps `now`.
      long_ago = DateTime.add(DateTime.utc_now(), -31, :day)

      Magus.Repo.update_all(
        from(p in Magus.Brain.Page, where: p.id == ^ancient.id),
        set: [deleted_at: long_ago]
      )

      {:ok, due} =
        Magus.Brain.Page
        |> Ash.Query.for_read(:trashed_for_cleanup)
        |> Ash.read(authorize?: false)

      ids = Enum.map(due, & &1.id)
      assert ancient.id in ids
      refute fresh.id in ids
    end
  end

  describe "destroy cascading" do
    test "destroying a trashed root hard-deletes descendants via FK cascade" do
      %{user: user, brain: brain} = setup_brain()
      {:ok, root} = Brain.create_page(brain.id, %{title: "Root"}, actor: user)

      {:ok, child} =
        Brain.create_page(brain.id, %{title: "Child", parent_page_id: root.id}, actor: user)

      {:ok, trashed} = Brain.soft_delete_page(root, actor: user)
      :ok = Brain.destroy_page(trashed, actor: user)

      assert is_nil(reload_or_nil(root.id))
      assert is_nil(reload_or_nil(child.id))
    end
  end

  defp reload_or_nil(id) do
    case Magus.Brain.Page
         |> Ash.Query.for_read(:read_including_trashed)
         |> Ash.Query.filter(id == ^id)
         |> Ash.read_one(authorize?: false) do
      {:ok, row} -> row
      _ -> nil
    end
  end
end
