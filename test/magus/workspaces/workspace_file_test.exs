defmodule Magus.Workspaces.WorkspaceFileTest do
  use Magus.ResourceCase, async: true

  alias Magus.Files

  defp create_file(user, attrs \\ %{}) do
    defaults = %{
      name: "test-file.txt",
      type: :document,
      mime_type: "text/plain",
      file_size: 1024,
      file_path: "/tmp/test-file-#{System.unique_integer([:positive])}.txt",
      user_id: user.id
    }

    # Use create_for_user action with authorize?: false to bypass storage limit checks
    Magus.Files.File
    |> Ash.Changeset.for_create(:create_for_user, Map.merge(defaults, attrs))
    |> Ash.create(authorize?: false)
  end

  describe "workspace files" do
    test "can create a file in a workspace" do
      owner = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Test", slug: "test-files"},
          actor: owner
        )

      {:ok, file} = create_file(owner, %{workspace_id: workspace.id})

      assert file.workspace_id == workspace.id
    end

    test "workspace member can read workspace files after a workspace-level grant" do
      owner = generate(user())
      member = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Test", slug: "test-file-read"},
          actor: owner
        )

      {:ok, invite} =
        Magus.Workspaces.invite_member(workspace.id, member.email, actor: owner)

      {:ok, _} = Magus.Workspaces.accept_invite(invite.invite_token, actor: member)

      {:ok, file} = create_file(owner, %{workspace_id: workspace.id})

      # Path B: workspace members need an explicit grant to see a file.
      {:ok, _} =
        Magus.Workspaces.ResourceAccess
        |> Ash.Changeset.for_create(
          :grant,
          %{
            resource_type: :file,
            resource_id: file.id,
            grantee_type: :workspace,
            grantee_id: workspace.id,
            role: :viewer
          },
          actor: owner
        )
        |> Ash.create()

      assert {:ok, found} = Files.get_file(file.id, actor: member)
      assert found.id == file.id
    end

    test "non-member cannot create a file in another workspace" do
      owner = generate(user())
      outsider = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Test", slug: "test-file-create-deny"},
          actor: owner
        )

      assert {:error, %Ash.Error.Invalid{}} =
               Files.create_file(
                 %{
                   name: "forbidden.txt",
                   type: :document,
                   mime_type: "text/plain",
                   file_size: 42,
                   file_path: "/tmp/forbidden.txt",
                   workspace_id: workspace.id
                 },
                 actor: outsider
               )
    end

    test "workspace owner can update a member-created workspace file" do
      owner = generate(user())
      member = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Test", slug: "test-file-owner-manage"},
          actor: owner
        )

      {:ok, invite} =
        Magus.Workspaces.invite_member(workspace.id, member.email, actor: owner)

      {:ok, _} = Magus.Workspaces.accept_invite(invite.invite_token, actor: member)

      {:ok, file} =
        create_file(member, %{
          name: "member-file.txt",
          file_size: 128,
          file_path: "/tmp/member-file.txt",
          workspace_id: workspace.id
        })

      assert {:ok, updated} =
               Files.update_file_status(file, %{status: :ready}, actor: owner)

      assert updated.status == :ready
    end

    test "non-member cannot read workspace files" do
      owner = generate(user())
      outsider = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Test", slug: "test-file-deny"},
          actor: owner
        )

      {:ok, file} = create_file(owner, %{workspace_id: workspace.id})

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Files.get_file(file.id, actor: outsider)
    end

    test "personal files remain unaffected" do
      user = generate(user())

      {:ok, file} = create_file(user)

      assert file.workspace_id == nil
      assert {:ok, found} = Files.get_file(file.id, actor: user)
      assert found.id == file.id
    end
  end
end
