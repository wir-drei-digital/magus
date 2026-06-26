defmodule Magus.Chat.FolderWorkspaceTest do
  use Magus.DataCase, async: false
  import Magus.Generators

  describe "is_shared_to_workspace calculation" do
    test "is true when a workspace-level grant exists for the folder" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, folder} =
        Magus.Chat.create_folder(%{name: "Shared", workspace_id: ws.id}, actor: user)

      {:ok, _grant} =
        Magus.Workspaces.grant_access(
          %{
            resource_type: :folder,
            resource_id: folder.id,
            grantee_type: :workspace,
            grantee_id: ws.id,
            role: :viewer
          },
          actor: user
        )

      {:ok, loaded} =
        Magus.Chat.get_folder(folder.id, actor: user, load: [:is_shared_to_workspace])

      assert loaded.is_shared_to_workspace == true
    end

    test "is false when no workspace grant exists" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, folder} =
        Magus.Chat.create_folder(%{name: "Private", workspace_id: ws.id}, actor: user)

      {:ok, loaded} =
        Magus.Chat.get_folder(folder.id, actor: user, load: [:is_shared_to_workspace])

      assert loaded.is_shared_to_workspace == false
    end
  end

  describe "list_for_workspace action" do
    test "returns folders for the workspace, loaded with is_shared_to_workspace" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, ws_folder} =
        Magus.Chat.create_folder(%{name: "Wf", workspace_id: ws.id}, actor: user)

      {:ok, _personal_folder} = Magus.Chat.create_folder(%{name: "Pf"}, actor: user)

      {:ok, folders} = Magus.Chat.list_workspace_folders(ws.id, actor: user)
      assert Enum.map(folders, & &1.id) == [ws_folder.id]
      assert Enum.all?(folders, fn f -> f.is_shared_to_workspace == false end)
    end
  end
end
