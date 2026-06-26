defmodule Magus.Files.FileTest do
  @moduledoc """
  Tests for Files.File with local file storage.

  Uses the local storage backend configured in test.exs.

  Tests use `actor: user` for user operations and `actor: @ai_agent`
  for system operations like status updates and batch reads.
  """
  use Magus.ResourceCase, async: true
  use Oban.Testing, repo: Magus.Repo

  alias Magus.Files
  alias Magus.Chat

  # AI agent actor for system operations
  @ai_agent %Magus.Agents.Support.AiAgent{}

  # Minimal valid PNG file (1x1 transparent pixel)
  @png_content <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49,
                 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06,
                 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44,
                 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D,
                 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42,
                 0x60, 0x82>>

  # File cleanup is intentionally skipped. The previous approach of snapshot-diffing
  # the uploads directory caused race conditions with parallel async tests that also
  # create files (e.g., CalculationsTest). Since test files are tiny and use unique
  # UUIDs, they don't interfere across test runs. Database records are cleaned by
  # Ecto sandbox. Run `rm -rf priv/static/uploads/files/` for manual cleanup.

  describe "create_image/3" do
    test "creates image file from binary content" do
      user = generate(user())

      {:ok, file} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "test.png", user_id: user.id},
          actor: @ai_agent
        )

      assert file.name == "test.png"
      assert file.type == :image
      assert file.mime_type == "image/png"
      assert file.source == :agent
      assert file.status == :ready
      assert file.file_size == byte_size(@png_content)
      assert file.file_path != nil

      # Verify file was actually stored
      {:ok, stored_content} = Magus.Files.Storage.get(file.file_path)
      assert stored_content == @png_content
    end

    test "creates image file with conversation association" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, file} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "conv-image.png", user_id: user.id, conversation_id: conversation.id},
          actor: @ai_agent
        )

      assert file.conversation_id == conversation.id
    end

    test "handles different image formats" do
      user = generate(user())

      # Test JPEG mime type
      {:ok, file} =
        Files.create_image_file(
          @png_content,
          "image/jpeg",
          %{name: "test.jpg", user_id: user.id},
          actor: @ai_agent
        )

      assert file.mime_type == "image/jpeg"
      assert String.ends_with?(file.file_path, ".jpg")
    end
  end

  describe "create_video/3" do
    test "creates video file from binary content" do
      user = generate(user())

      # Simple fake video content (just bytes for testing)
      video_content = <<0x00, 0x00, 0x00, 0x1C, 0x66, 0x74, 0x79, 0x70>>

      {:ok, file} =
        Files.create_video_file(
          video_content,
          "video/mp4",
          %{name: "test.mp4", user_id: user.id},
          actor: @ai_agent
        )

      assert file.name == "test.mp4"
      assert file.type == :video
      assert file.mime_type == "video/mp4"
      assert file.source == :agent
      assert file.status == :ready
    end
  end

  describe "my_files/1" do
    test "returns only user's files" do
      user1 = generate(user())
      user2 = generate(user())

      {:ok, file1} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "user1.png", user_id: user1.id},
          actor: @ai_agent
        )

      {:ok, _file2} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "user2.png", user_id: user2.id},
          actor: @ai_agent
        )

      {:ok, files} = Files.my_files(actor: user1)

      assert length(files) == 1
      assert hd(files).id == file1.id
    end
  end

  describe "for_conversation/1" do
    test "returns files for specific conversation" do
      user = generate(user())
      {:ok, conv1} = Chat.create_conversation(%{title: "Conv 1"}, actor: user)
      {:ok, conv2} = Chat.create_conversation(%{title: "Conv 2"}, actor: user)

      {:ok, file1} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "conv1.png", user_id: user.id, conversation_id: conv1.id},
          actor: @ai_agent
        )

      {:ok, _file2} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "conv2.png", user_id: user.id, conversation_id: conv2.id},
          actor: @ai_agent
        )

      {:ok, files} = Files.list_files_for_conversation(conv1.id, actor: user)

      assert length(files) == 1
      assert hd(files).id == file1.id
    end
  end

  describe "for_folder/1" do
    test "returns files for specific folder" do
      user = generate(user())
      folder = generate(folder(actor: user))

      # create_image doesn't accept folder_id directly, so we create then move
      {:ok, file} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "folder.png", user_id: user.id},
          actor: @ai_agent
        )

      # Move to folder
      {:ok, _moved} =
        Files.move_file_to_context(file, %{folder_id: folder.id}, actor: user)

      {:ok, files} = Files.list_files_for_folder(folder.id, actor: user)

      assert length(files) == 1
      assert hd(files).id == file.id
    end
  end

  describe "global_files/1" do
    test "returns files not tied to conversation or folder" do
      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{}, actor: user)

      {:ok, global_file} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "global.png", user_id: user.id},
          actor: @ai_agent
        )

      {:ok, _conv_file} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "conv.png", user_id: user.id, conversation_id: conv.id},
          actor: @ai_agent
        )

      {:ok, files} = Files.list_global_files(user.id, actor: user)

      assert length(files) == 1
      assert hd(files).id == global_file.id
    end
  end

  describe "by_ids/1" do
    test "returns files by IDs" do
      user = generate(user())

      {:ok, file1} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "r1.png", user_id: user.id},
          actor: @ai_agent
        )

      {:ok, file2} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "r2.png", user_id: user.id},
          actor: @ai_agent
        )

      {:ok, _file3} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "r3.png", user_id: user.id},
          actor: @ai_agent
        )

      {:ok, files} =
        Files.get_files_by_ids([file1.id, file2.id], actor: @ai_agent)

      file_ids = Enum.map(files, & &1.id)
      assert length(files) == 2
      assert file1.id in file_ids
      assert file2.id in file_ids
    end
  end

  describe "move_to_context/1" do
    test "moves file to folder" do
      user = generate(user())
      folder = generate(folder(actor: user))

      {:ok, file} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "movable.png", user_id: user.id},
          actor: @ai_agent
        )

      assert file.folder_id == nil

      {:ok, moved} =
        Files.move_file_to_context(file, %{folder_id: folder.id}, actor: user)

      assert moved.folder_id == folder.id
    end

    test "moves file to conversation" do
      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{}, actor: user)

      {:ok, file} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "movable.png", user_id: user.id},
          actor: @ai_agent
        )

      {:ok, moved} =
        Files.move_file_to_context(file, %{conversation_id: conv.id}, actor: user)

      assert moved.conversation_id == conv.id
    end

    test "moves file to global (removes associations)" do
      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{}, actor: user)

      {:ok, file} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "movable.png", user_id: user.id, conversation_id: conv.id},
          actor: @ai_agent
        )

      {:ok, moved} =
        Files.move_file_to_context(
          file,
          %{conversation_id: nil, folder_id: nil},
          actor: user
        )

      assert moved.conversation_id == nil
      assert moved.folder_id == nil
    end
  end

  describe "update_status/1" do
    test "updates file status" do
      user = generate(user())

      {:ok, file} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "status.png", user_id: user.id},
          actor: @ai_agent
        )

      {:ok, updated} =
        Files.update_file_status(file, %{status: :processing}, actor: @ai_agent)

      assert updated.status == :processing
    end

    test "updates status with error message" do
      user = generate(user())

      {:ok, file} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "error.png", user_id: user.id},
          actor: @ai_agent
        )

      {:ok, updated} =
        Files.update_file_status(
          file,
          %{status: :error, error_message: "Processing failed"},
          authorize?: false
        )

      assert updated.status == :error
      assert updated.error_message == "Processing failed"
    end
  end

  describe "destroy/1" do
    test "deletes file and stored content" do
      user = generate(user())

      {:ok, file} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "deletable.png", user_id: user.id},
          actor: @ai_agent
        )

      file_path = file.file_path

      # Verify file exists
      assert {:ok, _} = Magus.Files.Storage.get(file_path)

      # Delete file
      :ok = Files.delete_file(file, actor: user)

      # Verify file is gone
      {:error, _} = Files.get_file(file.id, actor: user)

      # Verify stored content is also deleted
      assert {:error, :enoent} = Magus.Files.Storage.get(file_path)
    end
  end

  describe "get_file/1" do
    test "returns file by ID" do
      user = generate(user())

      {:ok, file} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "findme.png", user_id: user.id},
          actor: @ai_agent
        )

      {:ok, found} = Files.get_file(file.id, actor: user)

      assert found.id == file.id
      assert found.name == "findme.png"
    end

    test "returns error for non-existent file" do
      user = generate(user())
      fake_id = Ash.UUIDv7.generate()

      {:error, _} = Files.get_file(fake_id, actor: user)
    end
  end

  describe "calculations" do
    test "display_info returns file display data" do
      user = generate(user())

      {:ok, file} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "display.png", user_id: user.id},
          actor: @ai_agent
        )

      {:ok, loaded} = Ash.load(file, :display_info, actor: @ai_agent)

      assert loaded.display_info["id"] == file.id
      assert loaded.display_info["name"] == "display.png"
      # DisplayInfo calculation converts type to string
      assert loaded.display_info["type"] == "image"
      assert loaded.display_info["mime_type"] == "image/png"
    end
  end

  describe "load_for_display/1" do
    test "loads display info for multiple files" do
      user = generate(user())

      {:ok, file1} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "r1.png", user_id: user.id},
          actor: @ai_agent
        )

      {:ok, file2} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "r2.png", user_id: user.id},
          actor: @ai_agent
        )

      {:ok, display_data} =
        Files.load_for_display([file1.id, file2.id], actor: @ai_agent)

      assert length(display_data) == 2
    end

    test "filters out files the actor cannot read" do
      owner = generate(user())
      stranger = generate(user())

      {:ok, owner_file} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "private.png", user_id: owner.id},
          actor: @ai_agent
        )

      assert {:ok, []} = Files.load_for_display([owner_file.id], actor: stranger)
      assert {:ok, [info]} = Files.load_for_display([owner_file.id], actor: owner)
      assert info["id"] == owner_file.id
    end
  end

  describe "load_llm_content_parts/1" do
    test "filters out files the actor cannot read" do
      owner = generate(user())
      stranger = generate(user())

      {:ok, owner_file} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "private.png", user_id: owner.id},
          actor: @ai_agent
        )

      assert {:ok, []} =
               Files.load_llm_content_parts([owner_file.id], actor: stranger)

      assert {:ok, [_]} =
               Files.load_llm_content_parts([owner_file.id], actor: owner)
    end
  end

  describe "load_first_image_data_uri/1" do
    test "returns nil when actor cannot read any of the files" do
      owner = generate(user())
      stranger = generate(user())

      {:ok, owner_file} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "private.png", user_id: owner.id},
          actor: @ai_agent
        )

      assert {:ok, nil} =
               Files.load_first_image_data_uri([owner_file.id], actor: stranger)

      assert {:ok, "data:image/png;base64," <> _} =
               Files.load_first_image_data_uri([owner_file.id], actor: owner)
    end
  end

  describe "storage tracking" do
    alias Magus.Usage

    setup do
      user = generate(user())
      free_plan = ensure_free_plan()

      {:ok, subscription} =
        Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
          authorize?: false
        )

      %{user: user, subscription: subscription}
    end

    test "create_image increments storage usage", %{user: user} do
      # Get initial storage
      {:ok, sub_before} = Usage.get_user_subscription(user.id, authorize?: false)
      initial_storage = sub_before.storage_usage_bytes

      {:ok, file} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "tracked.png", user_id: user.id},
          actor: @ai_agent
        )

      # Verify storage was incremented
      {:ok, sub_after} = Usage.get_user_subscription(user.id, authorize?: false)
      assert sub_after.storage_usage_bytes == initial_storage + file.file_size
    end

    test "create_video increments storage usage", %{user: user} do
      video_content = <<0x00, 0x00, 0x00, 0x1C, 0x66, 0x74, 0x79, 0x70>>

      {:ok, sub_before} = Usage.get_user_subscription(user.id, authorize?: false)
      initial_storage = sub_before.storage_usage_bytes

      {:ok, file} =
        Files.create_video_file(
          video_content,
          "video/mp4",
          %{name: "tracked.mp4", user_id: user.id},
          actor: @ai_agent
        )

      {:ok, sub_after} = Usage.get_user_subscription(user.id, authorize?: false)
      assert sub_after.storage_usage_bytes == initial_storage + file.file_size
    end

    test "delete decrements storage usage", %{user: user} do
      # Create a file first
      {:ok, file} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "deletable.png", user_id: user.id},
          actor: @ai_agent
        )

      {:ok, sub_before} = Usage.get_user_subscription(user.id, authorize?: false)

      # Delete the file
      :ok = Files.delete_file(file, actor: user)

      # Verify storage was decremented
      {:ok, sub_after} = Usage.get_user_subscription(user.id, authorize?: false)
      assert sub_after.storage_usage_bytes == sub_before.storage_usage_bytes - file.file_size
    end

    test "storage doesn't go negative on delete", %{user: user} do
      # Set storage to 0 manually (edge case)
      {:ok, sub} = Usage.get_user_subscription(user.id, authorize?: false)

      sub
      |> Ash.Changeset.for_update(:update_from_stripe, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:storage_usage_bytes, 0)
      |> Ash.update!(authorize?: false)

      # Create and immediately delete a file
      {:ok, file} =
        Files.create_image_file(
          @png_content,
          "image/png",
          %{name: "edge.png", user_id: user.id},
          actor: @ai_agent
        )

      # Reset storage to 0 again (simulating drift)
      {:ok, sub} = Usage.get_user_subscription(user.id, authorize?: false)

      sub
      |> Ash.Changeset.for_update(:update_from_stripe, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:storage_usage_bytes, 0)
      |> Ash.update!(authorize?: false)

      # Delete should not cause negative storage
      :ok = Files.delete_file(file, actor: user)

      {:ok, sub_after} = Usage.get_user_subscription(user.id, authorize?: false)
      assert sub_after.storage_usage_bytes == 0
    end
  end

  describe "connector storage limit enforcement" do
    alias Magus.Knowledge
    alias Magus.Usage

    setup do
      user = generate(user())
      free_plan = ensure_free_plan()

      {:ok, subscription} =
        Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
          authorize?: false
        )

      {:ok, source} =
        Knowledge.create_source(
          %{name: "Test", provider: :notion, auth_config: %{"key" => "test"}},
          actor: user
        )

      {:ok, collection} =
        Knowledge.create_collection(
          source.id,
          %{name: "Docs", external_id: "ext-collection-1", external_path: "/docs"},
          actor: user
        )

      %{user: user, subscription: subscription, free_plan: free_plan, collection: collection}
    end

    defp connector_file_attrs(content_size, collection) do
      path = create_temp_file(String.duplicate("x", content_size))

      %{
        name: "synced-doc.md",
        type: :document,
        mime_type: "text/markdown",
        file_size: content_size,
        file_path: path,
        knowledge_collection_id: collection.id,
        external_id: "ext-#{:rand.uniform(1_000_000)}",
        external_etag: "etag-1"
      }
    end

    test "create_from_connector increments storage usage", %{user: user, collection: collection} do
      {:ok, sub_before} = Usage.get_user_subscription(user.id, authorize?: false)
      file_size = 5_000

      {:ok, file} =
        Files.create_file_from_connector(connector_file_attrs(file_size, collection), actor: user)

      assert file.source == :connector
      assert file.file_size == file_size

      {:ok, sub_after} = Usage.get_user_subscription(user.id, authorize?: false)
      assert sub_after.storage_usage_bytes == sub_before.storage_usage_bytes + file_size
    end

    test "create_from_connector blocks when storage quota exceeded", %{
      user: user,
      free_plan: plan,
      collection: collection
    } do
      Usage.increment_storage_usage(user.id, plan.storage_bytes + 1_000, authorize?: false)

      result =
        Files.create_file_from_connector(connector_file_attrs(1_000, collection), actor: user)

      assert {:error, error} = result
      assert error_contains_message?(error, "over your storage limit")
    end

    test "create_from_connector blocks when file exceeds max_upload_bytes", %{
      user: user,
      free_plan: plan,
      collection: collection
    } do
      large_size = plan.max_upload_bytes + 1_000

      result =
        Files.create_file_from_connector(connector_file_attrs(large_size, collection),
          actor: user
        )

      assert {:error, error} = result
      assert error_contains_message?(error, "File too large")
    end

    test "update_from_connector tracks storage delta on size increase", %{
      user: user,
      collection: collection
    } do
      {:ok, file} =
        Files.create_file_from_connector(connector_file_attrs(5_000, collection), actor: user)

      {:ok, sub_before} = Usage.get_user_subscription(user.id, authorize?: false)

      # Update with larger file
      new_path = create_temp_file(String.duplicate("y", 8_000))

      {:ok, updated} =
        Files.update_file_from_connector(
          file,
          %{
            file_size: 8_000,
            file_path: new_path,
            external_etag: "etag-2",
            status: :pending
          },
          authorize?: false
        )

      assert updated.file_size == 8_000

      {:ok, sub_after} = Usage.get_user_subscription(user.id, authorize?: false)
      assert sub_after.storage_usage_bytes == sub_before.storage_usage_bytes + 3_000
    end

    test "update_from_connector tracks storage delta on size decrease", %{
      user: user,
      collection: collection
    } do
      {:ok, file} =
        Files.create_file_from_connector(connector_file_attrs(10_000, collection), actor: user)

      {:ok, sub_before} = Usage.get_user_subscription(user.id, authorize?: false)

      # Update with smaller file
      new_path = create_temp_file(String.duplicate("z", 4_000))

      {:ok, _updated} =
        Files.update_file_from_connector(
          file,
          %{
            file_size: 4_000,
            file_path: new_path,
            external_etag: "etag-3",
            status: :pending
          },
          authorize?: false
        )

      {:ok, sub_after} = Usage.get_user_subscription(user.id, authorize?: false)
      assert sub_after.storage_usage_bytes == sub_before.storage_usage_bytes - 6_000
    end

    test "update_from_connector no-ops storage when size unchanged", %{
      user: user,
      collection: collection
    } do
      {:ok, file} =
        Files.create_file_from_connector(connector_file_attrs(5_000, collection), actor: user)

      {:ok, sub_before} = Usage.get_user_subscription(user.id, authorize?: false)

      # Update metadata only, same size
      {:ok, _updated} =
        Files.update_file_from_connector(
          file,
          %{
            external_etag: "etag-4",
            status: :pending
          },
          authorize?: false
        )

      {:ok, sub_after} = Usage.get_user_subscription(user.id, authorize?: false)
      assert sub_after.storage_usage_bytes == sub_before.storage_usage_bytes
    end
  end

  describe "storage limit validation" do
    alias Magus.Usage

    setup do
      user = generate(user())
      free_plan = ensure_free_plan()

      {:ok, subscription} =
        Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
          authorize?: false
        )

      %{user: user, subscription: subscription, free_plan: free_plan}
    end

    test "blocks upload when in storage overage", %{user: user, free_plan: plan} do
      # Put user over storage quota
      Usage.increment_storage_usage(user.id, plan.storage_bytes + 1_000_000, authorize?: false)

      # Create a small test file
      path = create_temp_file(@png_content)

      # Try to upload using the :create action with proper actor context
      result =
        Files.create_file(
          %{
            name: "blocked.png",
            type: :image,
            mime_type: "image/png",
            file_size: byte_size(@png_content),
            file_path: path
          },
          actor: user
        )

      assert {:error, error} = result
      assert error_contains_message?(error, "over your storage limit")
    end

    test "blocks upload when file exceeds max_upload_bytes", %{user: user, free_plan: plan} do
      # Create a file larger than max upload size
      large_size = plan.max_upload_bytes + 1000
      path = create_temp_file(String.duplicate("x", large_size))

      # Try to upload using the :create action with proper actor context
      result =
        Files.create_file(
          %{
            name: "toolarge.bin",
            type: :document,
            mime_type: "application/octet-stream",
            file_size: large_size,
            file_path: path
          },
          actor: user
        )

      assert {:error, error} = result
      assert error_contains_message?(error, "File too large")
    end
  end

  # Helper to create a temporary file for testing
  defp create_temp_file(content) do
    path = Path.join(System.tmp_dir!(), "test_#{:rand.uniform(1_000_000)}")
    File.write!(path, content)
    path
  end

  # Helper to check if error contains a specific message
  defp error_contains_message?(%Ash.Error.Invalid{errors: errors}, message) do
    Enum.any?(errors, fn error ->
      msg = Map.get(error, :message, "")
      String.contains?(to_string(msg), message)
    end)
  end

  defp error_contains_message?(error, message) do
    case error do
      %{errors: errors} when is_list(errors) ->
        error_contains_message?(%Ash.Error.Invalid{errors: errors}, message)

      _ ->
        false
    end
  end

  describe "companion link cleanup" do
    test "destroying a file unlinks any companion conversations" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, file} =
        Magus.Files.create_file(
          %{
            name: "doc.pdf",
            type: :document,
            mime_type: "application/pdf",
            file_size: 1,
            file_path: "#{user.id}/#{Ash.UUIDv7.generate()}.pdf",
            workspace_id: ws.id
          },
          actor: user
        )

      {:ok, conv} =
        Magus.Chat.find_or_create_companion_conversation(:file, file.id, actor: user)

      :ok = Magus.Files.delete_file(file, actor: user)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Magus.Chat.get_companion_by_conversation(conv.id, actor: user)

      # Conversation itself remains
      assert {:ok, _} = Magus.Chat.get_conversation(conv.id, actor: user)
    end

    test "soft-deleting a file unlinks any companion conversations" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, file} =
        Magus.Files.create_file(
          %{
            name: "doc.pdf",
            type: :document,
            mime_type: "application/pdf",
            file_size: 1,
            file_path: "#{user.id}/#{Ash.UUIDv7.generate()}.pdf",
            workspace_id: ws.id
          },
          actor: user
        )

      {:ok, conv} =
        Magus.Chat.find_or_create_companion_conversation(:file, file.id, actor: user)

      {:ok, _} = Magus.Files.soft_delete_file(file, actor: user)

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               Magus.Chat.get_companion_by_conversation(conv.id, actor: user)

      # Conversation itself remains
      assert {:ok, _} = Magus.Chat.get_conversation(conv.id, actor: user)
    end
  end

  # ---------------------------------------------------------------------------
  # Browser scope read actions (Bundle A / Task 3)
  # ---------------------------------------------------------------------------

  defp browser_make_file(actor, attrs) do
    unique = System.unique_integer([:positive])
    type = Map.get(attrs, :type, :text)

    base = %{
      name: Map.get(attrs, :name, "f-#{unique}.txt"),
      type: type,
      mime_type: Map.get(attrs, :mime_type, "text/plain"),
      file_size: 1,
      file_path: "fbtest/#{unique}-#{Ash.UUIDv7.generate()}"
    }

    Magus.Files.File
    |> Ash.Changeset.for_create(:create, Map.merge(base, attrs), actor: actor)
    |> Ash.create!(authorize?: false)
  end

  defp browser_set_updated_at!(file, dt) do
    require Ecto.Query

    {1, _} =
      Magus.Repo.update_all(
        Ecto.Query.from(f in "files", where: f.id == ^Ecto.UUID.dump!(file.id)),
        set: [updated_at: dt, inserted_at: dt]
      )

    file
  end

  defp browser_add_active_member(workspace, admin_user, invitee) do
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

  describe "list_in_folder/1" do
    test "returns files whose folder_id matches" do
      user = generate(user())
      ensure_workspace_plan(user)
      folder = generate(folder(actor: user))
      f1 = browser_make_file(user, %{folder_id: folder.id, name: "f1"})
      f2 = browser_make_file(user, %{folder_id: folder.id, name: "f2"})
      _other = browser_make_file(user, %{name: "other"})

      ids =
        Magus.Files.list_files_in_folder!(folder.id, actor: user)
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert ids == Enum.sort([f1.id, f2.id])
    end
  end

  describe "list_recent/0" do
    test "includes files updated within the window" do
      user = generate(user())
      ensure_workspace_plan(user)
      fresh = browser_make_file(user, %{name: "fresh"})
      old_at = DateTime.add(DateTime.utc_now(), -60, :day)
      stale = browser_make_file(user, %{name: "stale"})
      _ = browser_set_updated_at!(stale, old_at)

      ids =
        Magus.Files.list_recent_files!(
          nil,
          DateTime.add(DateTime.utc_now(), -30, :day),
          actor: user
        )
        |> Enum.map(& &1.id)

      assert ids == [fresh.id]
    end
  end

  describe "list_shared_with_me/1" do
    test "returns workspace files I did not create" do
      creator = generate(user())
      ensure_workspace_plan(creator)
      stranger = generate(user())
      ensure_workspace_plan(stranger)

      {:ok, ws} =
        Magus.Workspaces.create_workspace(
          %{name: "WS", slug: "ws-shared-#{System.unique_integer([:positive])}"},
          actor: creator
        )

      :ok = browser_add_active_member(ws, creator, stranger)

      mine = browser_make_file(stranger, %{workspace_id: ws.id, name: "mine"})
      theirs = browser_make_file(creator, %{workspace_id: ws.id, name: "theirs"})

      # Grant the stranger access to the workspace files
      {:ok, _} =
        Magus.Workspaces.ResourceAccess
        |> Ash.Changeset.for_create(:grant, %{
          resource_type: :file,
          resource_id: theirs.id,
          grantee_type: :workspace,
          grantee_id: ws.id,
          role: :viewer
        })
        |> Ash.create(authorize?: false)

      ids =
        Magus.Files.list_shared_with_me_files!(ws.id, actor: stranger)
        |> Enum.map(& &1.id)

      refute mine.id in ids
      assert theirs.id in ids
    end
  end

  describe "list_trash/1" do
    test "returns soft-deleted files belonging to actor" do
      user = generate(user())
      ensure_workspace_plan(user)
      live = browser_make_file(user, %{name: "live"})
      trashed = browser_make_file(user, %{name: "trashed"})
      {:ok, _} = Magus.Files.soft_delete_file(trashed, actor: user)

      ids =
        Magus.Files.list_trash_files!(nil, actor: user)
        |> Enum.map(& &1.id)

      refute live.id in ids
      assert trashed.id in ids
    end
  end
end
