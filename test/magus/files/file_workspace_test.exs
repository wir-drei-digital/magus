defmodule Magus.Files.FileWorkspaceTest do
  @moduledoc """
  Tests for the generic workspace-scoped policy on `Magus.Files.File` backed by
  `Magus.Workspaces.ResourceAccess` grants, and for the
  `FolderInSameWorkspace` cross-scope validation.
  """
  use Magus.ResourceCase, async: true

  alias Magus.Chat.Folder
  alias Magus.Files
  alias Magus.Workspaces.ResourceAccess

  # Minimal valid PNG file (1x1 transparent pixel)
  @png_content <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49,
                 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06,
                 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44,
                 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D,
                 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42,
                 0x60, 0x82>>

  defp create_temp_file(content) do
    path = Path.join(System.tmp_dir!(), "test_#{:rand.uniform(1_000_000)}")
    Elixir.File.write!(path, content)
    path
  end

  defp create_workspace_file!(actor, workspace) do
    path = create_temp_file(@png_content)

    Files.create_file(
      %{
        name: "ws-file-#{:rand.uniform(1_000_000)}.png",
        type: :image,
        mime_type: "image/png",
        file_size: byte_size(@png_content),
        file_path: path,
        workspace_id: workspace.id
      },
      actor: actor
    )
  end

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

    test "creator can read their workspace file", %{creator: creator, workspace: workspace} do
      {:ok, file} = create_workspace_file!(creator, workspace)

      assert {:ok, _} = Files.get_file(file.id, actor: creator)
    end

    test "private workspace file (no grant) is hidden from strangers", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, file} = create_workspace_file!(creator, workspace)

      assert {:error, _} = Files.get_file(file.id, actor: stranger)
    end

    test "private workspace file (no grant) is hidden from active members without a grant", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, file} = create_workspace_file!(creator, workspace)

      :ok = add_active_member(workspace, creator, stranger)

      assert {:error, _} = Files.get_file(file.id, actor: stranger)
    end

    test "workspace :viewer grant lets an active member read", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, file} = create_workspace_file!(creator, workspace)

      :ok = add_active_member(workspace, creator, stranger)

      _grant =
        grant!(%{
          resource_type: :file,
          resource_id: file.id,
          grantee_type: :workspace,
          grantee_id: workspace.id,
          role: :viewer
        })

      assert {:ok, _} = Files.get_file(file.id, actor: stranger)
    end

    test "stranger (non-member) cannot see file even with workspace grant", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, file} = create_workspace_file!(creator, workspace)

      # Grant access to the workspace, but don't add the stranger as a member.
      _grant =
        grant!(%{
          resource_type: :file,
          resource_id: file.id,
          grantee_type: :workspace,
          grantee_id: workspace.id,
          role: :viewer
        })

      assert {:error, _} = Files.get_file(file.id, actor: stranger)
    end
  end

  describe "chunk authorization mirrors file authorization" do
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

    defp create_chunk!(file) do
      Magus.Files.create_chunk(
        %{
          file_id: file.id,
          content: "secret chunk content",
          position: 0,
          token_count: 4
        },
        authorize?: false
      )
    end

    test "creator can read chunks of their workspace file", %{
      creator: creator,
      workspace: workspace
    } do
      {:ok, file} = create_workspace_file!(creator, workspace)
      {:ok, _chunk} = create_chunk!(file)

      assert {:ok, [chunk]} = Files.get_chunks_for_file(file.id, actor: creator)
      assert chunk.file_id == file.id
    end

    test "stranger (non-member) cannot read chunks of a workspace file", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, file} = create_workspace_file!(creator, workspace)
      {:ok, _chunk} = create_chunk!(file)

      assert {:ok, []} = Files.get_chunks_for_file(file.id, actor: stranger)
    end

    test "active workspace member without a grant cannot read chunks of a private workspace file",
         %{creator: creator, stranger: stranger, workspace: workspace} do
      {:ok, file} = create_workspace_file!(creator, workspace)
      {:ok, _chunk} = create_chunk!(file)

      :ok = add_active_member(workspace, creator, stranger)

      assert {:ok, []} = Files.get_chunks_for_file(file.id, actor: stranger)
    end

    test "active workspace member with a workspace :viewer grant can read chunks", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, file} = create_workspace_file!(creator, workspace)
      {:ok, _chunk} = create_chunk!(file)

      :ok = add_active_member(workspace, creator, stranger)

      _grant =
        grant!(%{
          resource_type: :file,
          resource_id: file.id,
          grantee_type: :workspace,
          grantee_id: workspace.id,
          role: :viewer
        })

      assert {:ok, [chunk]} = Files.get_chunks_for_file(file.id, actor: stranger)
      assert chunk.file_id == file.id
    end

    test "user with a direct :viewer grant can read chunks even without membership", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, file} = create_workspace_file!(creator, workspace)
      {:ok, _chunk} = create_chunk!(file)

      _grant =
        grant!(%{
          resource_type: :file,
          resource_id: file.id,
          grantee_type: :user,
          grantee_id: stranger.id,
          role: :viewer
        })

      assert {:ok, [chunk]} = Files.get_chunks_for_file(file.id, actor: stranger)
      assert chunk.file_id == file.id
    end
  end

  describe "FolderInSameWorkspace validation" do
    setup do
      creator = generate(user())
      ensure_workspace_plan(creator)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "T", slug: "t-#{System.unique_integer([:positive])}"},
          actor: creator
        )

      %{creator: creator, workspace: workspace}
    end

    test "cannot create a workspace file under a personal folder", %{
      creator: creator,
      workspace: workspace
    } do
      {:ok, personal_folder} =
        Folder
        |> Ash.Changeset.for_create(:create, %{name: "Personal"}, actor: creator)
        |> Ash.create()

      path = create_temp_file(@png_content)

      assert {:error, %Ash.Error.Invalid{} = err} =
               Files.create_file(
                 %{
                   name: "bad.png",
                   type: :image,
                   mime_type: "image/png",
                   file_size: byte_size(@png_content),
                   file_path: path,
                   workspace_id: workspace.id,
                   folder_id: personal_folder.id
                 },
                 actor: creator
               )

      assert Exception.message(err) =~ "same workspace"
    end

    test "can create a workspace file inside a workspace folder", %{
      creator: creator,
      workspace: workspace
    } do
      {:ok, ws_folder} =
        Folder
        |> Ash.Changeset.for_create(
          :create,
          %{name: "WS Folder", workspace_id: workspace.id},
          actor: creator
        )
        |> Ash.create()

      path = create_temp_file(@png_content)

      assert {:ok, file} =
               Files.create_file(
                 %{
                   name: "ok.png",
                   type: :image,
                   mime_type: "image/png",
                   file_size: byte_size(@png_content),
                   file_path: path,
                   workspace_id: workspace.id,
                   folder_id: ws_folder.id
                 },
                 actor: creator
               )

      assert file.folder_id == ws_folder.id
      assert file.workspace_id == workspace.id
    end

    test "move_to_context rejects a cross-scope folder", %{creator: creator, workspace: workspace} do
      # Create a workspace file with no folder.
      {:ok, file} = create_workspace_file!(creator, workspace)

      # Create a personal folder (no workspace_id) owned by the same user.
      {:ok, personal_folder} =
        Folder
        |> Ash.Changeset.for_create(:create, %{name: "Personal"}, actor: creator)
        |> Ash.create()

      assert {:error, err} =
               Files.move_file_to_context(
                 file,
                 %{folder_id: personal_folder.id},
                 actor: creator
               )

      assert Exception.message(err) =~ "same workspace" or
               Exception.message(err) =~ "must be a folder the actor owns"
    end
  end

  describe "is_shared_to_workspace calculation" do
    setup do
      creator = generate(user())
      ensure_workspace_plan(creator)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "T", slug: "t-#{System.unique_integer([:positive])}"},
          actor: creator
        )

      %{creator: creator, workspace: workspace}
    end

    test "is true when a workspace-level grant exists for the file", %{
      creator: creator,
      workspace: workspace
    } do
      {:ok, file} = create_workspace_file!(creator, workspace)

      _grant =
        grant!(%{
          resource_type: :file,
          resource_id: file.id,
          grantee_type: :workspace,
          grantee_id: workspace.id,
          role: :viewer
        })

      {:ok, loaded} =
        Files.get_file(file.id, actor: creator, load: [:is_shared_to_workspace])

      assert loaded.is_shared_to_workspace == true
    end

    test "is false when no workspace grant exists", %{
      creator: creator,
      workspace: workspace
    } do
      {:ok, file} = create_workspace_file!(creator, workspace)

      {:ok, loaded} =
        Files.get_file(file.id, actor: creator, load: [:is_shared_to_workspace])

      assert loaded.is_shared_to_workspace == false
    end

    test "is false when file has no workspace_id (personal)", %{creator: creator} do
      path = create_temp_file(@png_content)

      {:ok, file} =
        Files.create_file(
          %{
            name: "personal-#{:rand.uniform(1_000_000)}.png",
            type: :image,
            mime_type: "image/png",
            file_size: byte_size(@png_content),
            file_path: path
          },
          actor: creator
        )

      {:ok, loaded} =
        Files.get_file(file.id, actor: creator, load: [:is_shared_to_workspace])

      assert loaded.is_shared_to_workspace == false
    end
  end

  describe "destroy grant cleanup" do
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

    test "destroying a file cleans up its ResourceAccess grants", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, file} = create_workspace_file!(creator, workspace)
      :ok = add_active_member(workspace, creator, stranger)

      _grant =
        grant!(%{
          resource_type: :file,
          resource_id: file.id,
          grantee_type: :workspace,
          grantee_id: workspace.id,
          role: :viewer
        })

      # Precondition: the grant exists.
      {:ok, grants_before} =
        ResourceAccess
        |> Ash.Query.for_read(:for_resource, %{resource_type: :file, resource_id: file.id})
        |> Ash.read(authorize?: false)

      assert length(grants_before) == 1

      :ok = Files.delete_file(file, actor: creator)

      {:ok, grants_after} =
        ResourceAccess
        |> Ash.Query.for_read(:for_resource, %{resource_type: :file, resource_id: file.id})
        |> Ash.read(authorize?: false)

      assert grants_after == []
    end

    test "soft_delete on a file cleans up its ResourceAccess grants", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, file} = create_workspace_file!(creator, workspace)
      :ok = add_active_member(workspace, creator, stranger)

      _grant =
        grant!(%{
          resource_type: :file,
          resource_id: file.id,
          grantee_type: :workspace,
          grantee_id: workspace.id,
          role: :viewer
        })

      {:ok, _} =
        file
        |> Ash.Changeset.for_update(:soft_delete, %{}, actor: creator)
        |> Ash.update()

      {:ok, grants_after} =
        ResourceAccess
        |> Ash.Query.for_read(:for_resource, %{resource_type: :file, resource_id: file.id})
        |> Ash.read(authorize?: false)

      assert grants_after == []
    end
  end

  describe "personal_library_files action" do
    defp create_personal_file!(actor, attrs \\ %{}) do
      path = create_temp_file(@png_content)

      Files.create_file(
        Map.merge(
          %{
            name: "personal-#{:rand.uniform(1_000_000)}.png",
            type: :image,
            mime_type: "image/png",
            file_size: byte_size(@png_content),
            file_path: path
          },
          attrs
        ),
        actor: actor
      )
    end

    test "returns user's no-workspace files with no conversation_id" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, _ws_file} = create_workspace_file!(user, ws)

      {:ok, library} = create_personal_file!(user)

      {:ok, conv} = Magus.Chat.create_conversation(%{title: "c"}, actor: user)

      {:ok, _conv_file} = create_personal_file!(user, %{conversation_id: conv.id})

      {:ok, files} = Magus.Files.list_personal_library_files(actor: user)
      assert Enum.map(files, & &1.id) == [library.id]
    end
  end

  describe "workspace_library_files action" do
    test "returns workspace files with no conversation_id, loaded with is_shared_to_workspace" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, library} = create_workspace_file!(user, ws)

      {:ok, conv} =
        Magus.Chat.create_conversation(%{title: "c", workspace_id: ws.id}, actor: user)

      path = create_temp_file(@png_content)

      {:ok, _conv_file} =
        Files.create_file(
          %{
            name: "wconv-#{:rand.uniform(1_000_000)}.png",
            type: :image,
            mime_type: "image/png",
            file_size: byte_size(@png_content),
            file_path: path,
            workspace_id: ws.id,
            conversation_id: conv.id
          },
          actor: user
        )

      {:ok, files} = Magus.Files.list_workspace_library_files(ws.id, actor: user)
      assert Enum.map(files, & &1.id) == [library.id]
      assert Enum.all?(files, fn f -> f.is_shared_to_workspace == false end)
    end
  end

  describe "files_for_collection action" do
    test "returns files for a knowledge collection" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, source} =
        Magus.Knowledge.create_source(
          %{name: "src", provider: :google_drive, auth_config: %{"key" => "test"}},
          actor: user
        )

      {:ok, coll} =
        Magus.Knowledge.create_collection(
          source.id,
          %{name: "c", external_id: "x", external_path: "/c"},
          actor: user
        )

      {:ok, file} =
        Files.create_file_from_connector(
          %{
            name: "kf.txt",
            type: :text,
            mime_type: "text/plain",
            file_size: 1,
            file_path: "f/kf.txt",
            knowledge_collection_id: coll.id,
            external_id: "ext_kf_1"
          },
          actor: user
        )

      {:ok, files} = Magus.Files.list_files_for_collection(coll.id, actor: user)
      assert Enum.map(files, & &1.id) == [file.id]
    end
  end
end
