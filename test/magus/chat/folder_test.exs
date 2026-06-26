defmodule Magus.Chat.FolderTest do
  use Magus.ResourceCase, async: true

  require Ash.Query

  alias Magus.Chat
  alias Magus.Chat.Folder
  alias Magus.Workspaces
  alias Magus.Workspaces.ResourceAccess

  defp add_active_member(workspace, admin_user, invitee) do
    {:ok, m} =
      Magus.Workspaces.WorkspaceMember
      |> Ash.Changeset.for_create(
        :invite,
        %{workspace_id: workspace.id, invite_email: invitee.email},
        actor: admin_user
      )
      |> Ash.create()

    {:ok, _} =
      m
      |> Ash.Changeset.for_update(:accept, %{}, actor: invitee)
      |> Ash.update()

    :ok
  end

  defp grant!(attrs) do
    {:ok, grant} =
      ResourceAccess
      |> Ash.Changeset.for_create(:grant, attrs)
      |> Ash.create(authorize?: false)

    grant
  end

  describe "create/1" do
    test "creates folder with valid name" do
      user = generate(user())

      {:ok, folder} = Chat.create_folder(%{name: "My Folder"}, actor: user)

      assert folder.name == "My Folder"
      assert folder.user_id == user.id
      assert folder.parent_id == nil
      assert folder.position == 0
    end

    test "creates nested folder" do
      user = generate(user())

      parent = generate(folder(actor: user))

      {:ok, child} =
        Chat.create_folder(%{name: "Child Folder", parent_id: parent.id}, actor: user)

      assert child.parent_id == parent.id
    end

    test "creates folder with position" do
      user = generate(user())

      {:ok, folder} = Chat.create_folder(%{name: "Positioned", position: 5}, actor: user)

      assert folder.position == 5
    end

    test "requires name" do
      user = generate(user())

      {:error, _} = Chat.create_folder(%{}, actor: user)
    end
  end

  describe "update/1" do
    test "updates folder name" do
      user = generate(user())
      folder = generate(folder(actor: user))

      {:ok, updated} =
        Chat.update_folder(folder, %{name: "Renamed Folder"}, actor: user)

      assert updated.name == "Renamed Folder"
    end

    test "updates folder position" do
      user = generate(user())
      folder = generate(folder(actor: user))

      {:ok, updated} =
        Chat.update_folder(folder, %{position: 10}, actor: user)

      assert updated.position == 10
    end
  end

  describe "move_to_folder/1" do
    test "moves folder to parent" do
      user = generate(user())
      parent = generate(folder(actor: user))
      child = generate(folder(actor: user))

      {:ok, moved} =
        Chat.move_folder(child, %{parent_id: parent.id}, actor: user)

      assert moved.parent_id == parent.id
    end

    test "moves folder to root" do
      user = generate(user())
      parent = generate(folder(actor: user))

      {:ok, child} =
        Chat.create_folder(%{name: "Child", parent_id: parent.id}, actor: user)

      {:ok, moved} =
        Chat.move_folder(child, %{parent_id: nil}, actor: user)

      assert moved.parent_id == nil
    end
  end

  describe "my_folders/1" do
    test "returns only user's folders" do
      user1 = generate(user())
      user2 = generate(user())

      folder1 = generate(folder(actor: user1))
      _folder2 = generate(folder(actor: user2))

      {:ok, folders} = Chat.my_folders(actor: user1)

      assert length(folders) == 1
      assert hd(folders).id == folder1.id
    end
  end

  describe "root_folders/1" do
    test "returns only top-level folders" do
      user = generate(user())

      parent = generate(folder(actor: user))

      {:ok, _child} =
        Chat.create_folder(%{name: "Child", parent_id: parent.id}, actor: user)

      {:ok, root_folders} = Chat.root_folders(actor: user)

      # Only the parent should be returned
      assert length(root_folders) == 1
      assert hd(root_folders).id == parent.id
    end
  end

  describe "list_folders_in_folder/1" do
    setup do
      user = generate(user())
      parent = generate(folder(actor: user))
      child_a = generate(folder(actor: user, parent_id: parent.id, name: "A"))
      child_b = generate(folder(actor: user, parent_id: parent.id, name: "B"))
      sibling = generate(folder(actor: user))
      %{user: user, parent: parent, child_a: child_a, child_b: child_b, sibling: sibling}
    end

    test "returns only direct children of the parent", %{
      user: user,
      parent: parent,
      child_a: a,
      child_b: b,
      sibling: sibling
    } do
      ids =
        Chat.list_folders_in_folder!(parent.id, actor: user)
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert ids == Enum.sort([a.id, b.id])
      refute sibling.id in ids
    end

    test "sorts by name ascending", %{user: user, parent: parent} do
      _z = generate(folder(actor: user, parent_id: parent.id, name: "Z"))
      _a = generate(folder(actor: user, parent_id: parent.id, name: "Aardvark"))
      names = Chat.list_folders_in_folder!(parent.id, actor: user) |> Enum.map(& &1.name)
      assert names == Enum.sort(names)
    end
  end

  describe "destroy/1" do
    test "deletes folder" do
      user = generate(user())
      folder = generate(folder(actor: user))

      :ok = Chat.delete_folder(folder, actor: user)

      {:error, _} = Chat.get_folder(folder.id, actor: user)
    end

    test "child folders have parent_id set to nil when parent is deleted" do
      user = generate(user())
      parent = generate(folder(actor: user))

      {:ok, child} =
        Chat.create_folder(%{name: "Child", parent_id: parent.id}, actor: user)

      :ok = Chat.delete_folder(parent, actor: user)

      # Child should still exist but with nil parent
      {:ok, orphaned} = Chat.get_folder(child.id, actor: user)
      assert orphaned.parent_id == nil
    end
  end

  describe "relationships" do
    test "folder has many conversations" do
      user = generate(user())
      folder = generate(folder(actor: user))

      {:ok, conversation} =
        Chat.create_conversation(%{folder_id: folder.id}, actor: user)

      {:ok, loaded} = Ash.load(folder, :conversations, actor: user)

      assert length(loaded.conversations) == 1
      assert hd(loaded.conversations).id == conversation.id
    end

    test "folder has many children" do
      user = generate(user())
      parent = generate(folder(actor: user))

      {:ok, child1} =
        Chat.create_folder(%{name: "Child 1", parent_id: parent.id}, actor: user)

      {:ok, child2} =
        Chat.create_folder(%{name: "Child 2", parent_id: parent.id}, actor: user)

      {:ok, loaded} = Ash.load(parent, :children, actor: user)

      child_ids = Enum.map(loaded.children, & &1.id)
      assert child1.id in child_ids
      assert child2.id in child_ids
    end
  end

  describe "workspace scoping" do
    setup do
      creator = generate(user())
      stranger = generate(user())
      ensure_workspace_plan(creator)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "T", slug: "t-#{System.unique_integer([:positive])}"},
          actor: creator
        )

      %{creator: creator, stranger: stranger, workspace: workspace}
    end

    test "can create a personal folder", %{creator: creator} do
      assert {:ok, f} =
               Folder
               |> Ash.Changeset.for_create(:create, %{name: "Personal"}, actor: creator)
               |> Ash.create()

      assert is_nil(f.workspace_id)
    end

    test "can create a workspace folder", %{creator: creator, workspace: workspace} do
      assert {:ok, f} =
               Folder
               |> Ash.Changeset.for_create(
                 :create,
                 %{name: "WS", workspace_id: workspace.id},
                 actor: creator
               )
               |> Ash.create()

      assert f.workspace_id == workspace.id
    end

    test "workspace folder is not visible to strangers", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, f} =
        Folder
        |> Ash.Changeset.for_create(
          :create,
          %{name: "WS", workspace_id: workspace.id},
          actor: creator
        )
        |> Ash.create()

      assert {:error, _} = Ash.get(Folder, f.id, actor: stranger)
    end

    test "active workspace member does NOT see workspace folder without a grant", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, f} =
        Folder
        |> Ash.Changeset.for_create(
          :create,
          %{name: "WS", workspace_id: workspace.id},
          actor: creator
        )
        |> Ash.create()

      :ok = add_active_member(workspace, creator, stranger)

      assert {:error, _} = Ash.get(Folder, f.id, actor: stranger)
    end

    test "workspace :viewer grant lets an active member read", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, f} =
        Folder
        |> Ash.Changeset.for_create(
          :create,
          %{name: "WS", workspace_id: workspace.id},
          actor: creator
        )
        |> Ash.create()

      :ok = add_active_member(workspace, creator, stranger)

      _grant =
        grant!(%{
          resource_type: :folder,
          resource_id: f.id,
          grantee_type: :workspace,
          grantee_id: workspace.id,
          role: :viewer
        })

      assert {:ok, _} = Ash.get(Folder, f.id, actor: stranger)
    end

    test "cannot nest a workspace folder under a personal folder", %{
      creator: creator,
      workspace: workspace
    } do
      {:ok, personal} =
        Folder
        |> Ash.Changeset.for_create(:create, %{name: "Personal"}, actor: creator)
        |> Ash.create()

      assert {:error, %Ash.Error.Invalid{} = err} =
               Folder
               |> Ash.Changeset.for_create(
                 :create,
                 %{name: "Child", workspace_id: workspace.id, parent_id: personal.id},
                 actor: creator
               )
               |> Ash.create()

      assert Exception.message(err) =~ "same workspace"
    end
  end

  describe "is_shared_to_workspace calculation" do
    test "returns false for personal folder" do
      user = generate(user())
      folder = Chat.create_folder!(%{name: "Drafts"}, actor: user)

      folder = Ash.load!(folder, :is_shared_to_workspace, actor: user)
      assert folder.is_shared_to_workspace == false
    end

    test "returns false for unshared workspace folder" do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))

      folder =
        Chat.create_folder!(
          %{name: "Drafts", workspace_id: workspace.id},
          actor: user
        )

      folder = Ash.load!(folder, :is_shared_to_workspace, actor: user)
      assert folder.is_shared_to_workspace == false
    end

    test "returns true after a workspace grant exists" do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))

      folder =
        Chat.create_folder!(
          %{name: "Drafts", workspace_id: workspace.id},
          actor: user
        )

      Workspaces.grant_access(
        %{
          resource_type: :folder,
          resource_id: folder.id,
          grantee_type: :workspace,
          grantee_id: workspace.id,
          role: :viewer
        },
        actor: user
      )

      folder = Ash.load!(folder, :is_shared_to_workspace, actor: user)
      assert folder.is_shared_to_workspace == true
    end
  end

  describe "share_to_team / unshare_from_team" do
    test "share_to_team creates a workspace grant idempotently" do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))

      folder =
        Chat.create_folder!(
          %{name: "Roadmap", workspace_id: workspace.id},
          actor: user
        )

      folder = Chat.share_folder_to_team!(folder, actor: user)

      assert Ash.load!(folder, :is_shared_to_workspace, actor: user).is_shared_to_workspace ==
               true

      # Idempotent: a second call must not raise
      folder = Chat.share_folder_to_team!(folder, actor: user)

      assert Ash.load!(folder, :is_shared_to_workspace, actor: user).is_shared_to_workspace ==
               true
    end

    test "unshare_from_team revokes the workspace grant idempotently" do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))

      folder =
        Chat.create_folder!(
          %{name: "Roadmap", workspace_id: workspace.id},
          actor: user
        )

      Chat.share_folder_to_team!(folder, actor: user)
      folder = Chat.unshare_folder_from_team!(folder, actor: user)

      assert Ash.load!(folder, :is_shared_to_workspace, actor: user).is_shared_to_workspace ==
               false

      # Idempotent
      folder = Chat.unshare_folder_from_team!(folder, actor: user)

      assert Ash.load!(folder, :is_shared_to_workspace, actor: user).is_shared_to_workspace ==
               false
    end

    test "share_to_team raises when folder has no workspace_id" do
      user = generate(user())
      folder = Chat.create_folder!(%{name: "Drafts"}, actor: user)

      assert_raise Ash.Error.Invalid, fn ->
        Chat.share_folder_to_team!(folder, actor: user)
      end
    end

    test "share_to_team cascades to child conversations" do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))

      folder =
        Chat.create_folder!(%{name: "Roadmap", workspace_id: workspace.id}, actor: user)

      conv =
        Chat.create_conversation!(
          %{title: "child", workspace_id: workspace.id, folder_id: folder.id},
          actor: user
        )

      Chat.share_folder_to_team!(folder, actor: user)

      assert Ash.load!(conv, :is_shared_to_workspace, actor: user).is_shared_to_workspace ==
               true
    end

    test "share_to_team cascades recursively to sub-folders and their conversations" do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))

      root =
        Chat.create_folder!(%{name: "Root", workspace_id: workspace.id}, actor: user)

      sub =
        Chat.create_folder!(
          %{name: "Sub", workspace_id: workspace.id, parent_id: root.id},
          actor: user
        )

      conv =
        Chat.create_conversation!(
          %{title: "deep", workspace_id: workspace.id, folder_id: sub.id},
          actor: user
        )

      Chat.share_folder_to_team!(root, actor: user)

      assert Ash.load!(sub, :is_shared_to_workspace, actor: user).is_shared_to_workspace ==
               true

      assert Ash.load!(conv, :is_shared_to_workspace, actor: user).is_shared_to_workspace ==
               true
    end

    test "unshare_from_team cascades to child conversations" do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))

      folder =
        Chat.create_folder!(%{name: "Roadmap", workspace_id: workspace.id}, actor: user)

      conv =
        Chat.create_conversation!(
          %{title: "child", workspace_id: workspace.id, folder_id: folder.id},
          actor: user
        )

      Chat.share_folder_to_team!(folder, actor: user)
      Chat.unshare_folder_from_team!(folder, actor: user)

      assert Ash.load!(conv, :is_shared_to_workspace, actor: user).is_shared_to_workspace ==
               false
    end

    test "unshare_from_team cascades recursively to sub-folders and their conversations" do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))

      root =
        Chat.create_folder!(%{name: "Root", workspace_id: workspace.id}, actor: user)

      sub =
        Chat.create_folder!(
          %{name: "Sub", workspace_id: workspace.id, parent_id: root.id},
          actor: user
        )

      conv =
        Chat.create_conversation!(
          %{title: "deep", workspace_id: workspace.id, folder_id: sub.id},
          actor: user
        )

      Chat.share_folder_to_team!(root, actor: user)
      Chat.unshare_folder_from_team!(root, actor: user)

      assert Ash.load!(sub, :is_shared_to_workspace, actor: user).is_shared_to_workspace ==
               false

      assert Ash.load!(conv, :is_shared_to_workspace, actor: user).is_shared_to_workspace ==
               false
    end

    # Pinned behavior: cascade-unshare also strips grants that were created
    # outside the cascade (e.g. via a direct `share_conversation_to_team`).
    # `ResourceAccess` has no provenance, so the cascade can't distinguish
    # "shared because of the folder" from "shared independently". This matches
    # the user-facing model "everything in this folder is private now".
    test "unshare cascade also revokes pre-existing direct shares on children" do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))

      folder =
        Chat.create_folder!(%{name: "Roadmap", workspace_id: workspace.id}, actor: user)

      conv =
        Chat.create_conversation!(
          %{title: "direct-shared", workspace_id: workspace.id, folder_id: folder.id},
          actor: user
        )

      Chat.share_conversation_to_team!(conv, actor: user)
      Chat.unshare_folder_from_team!(folder, actor: user)

      assert Ash.load!(conv, :is_shared_to_workspace, actor: user).is_shared_to_workspace ==
               false
    end

    test "share is idempotent across multiple calls" do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))

      folder =
        Chat.create_folder!(%{name: "Roadmap", workspace_id: workspace.id}, actor: user)

      conv =
        Chat.create_conversation!(
          %{title: "child", workspace_id: workspace.id, folder_id: folder.id},
          actor: user
        )

      Chat.share_folder_to_team!(folder, actor: user)
      Chat.share_folder_to_team!(folder, actor: user)
      Chat.share_folder_to_team!(folder, actor: user)

      grants =
        ResourceAccess
        |> Ash.Query.filter(
          resource_type == :conversation and
            resource_id == ^conv.id and
            grantee_type == :workspace
        )
        |> Ash.read!(authorize?: false)

      assert length(grants) == 1
    end

    test "share cascade skips soft-deleted conversations" do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))

      folder =
        Chat.create_folder!(%{name: "Roadmap", workspace_id: workspace.id}, actor: user)

      conv =
        Chat.create_conversation!(
          %{title: "trashed", workspace_id: workspace.id, folder_id: folder.id},
          actor: user
        )

      Chat.soft_delete_conversation!(conv, actor: user)
      Chat.share_folder_to_team!(folder, actor: user)

      assert Ash.load!(conv, :is_shared_to_workspace, actor: user).is_shared_to_workspace ==
               false
    end
  end

  describe "move_to_folder share sync" do
    test "moving an unshared conversation into a shared folder auto-shares it" do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))

      folder =
        Chat.create_folder!(%{name: "Shared", workspace_id: workspace.id}, actor: user)

      Chat.share_folder_to_team!(folder, actor: user)

      conv =
        Chat.create_conversation!(%{title: "loner", workspace_id: workspace.id}, actor: user)

      Chat.move_conversation_to_folder!(conv, %{folder_id: folder.id}, actor: user)

      assert Ash.load!(conv, :is_shared_to_workspace, actor: user).is_shared_to_workspace ==
               true
    end

    test "moving a shared conversation into an unshared folder unshares it" do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))

      private = Chat.create_folder!(%{name: "Private", workspace_id: workspace.id}, actor: user)

      conv =
        Chat.create_conversation!(%{title: "shared", workspace_id: workspace.id}, actor: user)

      Chat.share_conversation_to_team!(conv, actor: user)

      Chat.move_conversation_to_folder!(conv, %{folder_id: private.id}, actor: user)

      assert Ash.load!(conv, :is_shared_to_workspace, actor: user).is_shared_to_workspace ==
               false
    end

    test "moving a conversation to no folder preserves its share state" do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))

      conv =
        Chat.create_conversation!(%{title: "free", workspace_id: workspace.id}, actor: user)

      Chat.share_conversation_to_team!(conv, actor: user)

      Chat.move_conversation_to_folder!(conv, %{folder_id: nil}, actor: user)

      assert Ash.load!(conv, :is_shared_to_workspace, actor: user).is_shared_to_workspace ==
               true
    end

    test "moving a folder into a shared parent cascades share to it and its descendants" do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))

      parent = Chat.create_folder!(%{name: "Parent", workspace_id: workspace.id}, actor: user)
      Chat.share_folder_to_team!(parent, actor: user)

      sub = Chat.create_folder!(%{name: "Sub", workspace_id: workspace.id}, actor: user)

      conv =
        Chat.create_conversation!(
          %{title: "child", workspace_id: workspace.id, folder_id: sub.id},
          actor: user
        )

      Chat.move_folder!(sub, %{parent_id: parent.id}, actor: user)

      assert Ash.load!(sub, :is_shared_to_workspace, actor: user).is_shared_to_workspace ==
               true

      assert Ash.load!(conv, :is_shared_to_workspace, actor: user).is_shared_to_workspace ==
               true
    end
  end

  describe "kind attribute" do
    test "defaults to :conversations when not provided" do
      user = generate(user())
      {:ok, folder} = Magus.Chat.create_folder(%{name: "x"}, actor: user)
      assert folder.kind == :conversations
    end

    test "accepts :files explicitly" do
      user = generate(user())
      {:ok, folder} = Magus.Chat.create_folder(%{name: "x", kind: :files}, actor: user)
      assert folder.kind == :files
    end

    test "rejects unknown atoms" do
      user = generate(user())

      assert {:error, %Ash.Error.Invalid{}} =
               Magus.Chat.create_folder(%{name: "x", kind: :foo}, actor: user)
    end
  end
end
