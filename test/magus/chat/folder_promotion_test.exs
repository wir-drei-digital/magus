defmodule Magus.Chat.FolderPromotionTest do
  @moduledoc """
  Cross-kind content placement promotes folder kind to :mixed.
  """
  use Magus.ResourceCase, async: false

  import Magus.Generators

  describe "promote on file create" do
    test "file in :conversations folder promotes folder to :mixed" do
      user = generate(user()) |> ensure_workspace_plan()

      {:ok, folder} =
        Magus.Chat.create_folder(%{name: "Chats", kind: :conversations}, actor: user)

      _file = generate(file(actor: user, folder_id: folder.id))

      reloaded = Magus.Chat.get_folder!(folder.id, actor: user)
      assert reloaded.kind == :mixed
    end

    test "file in :files folder leaves folder as :files" do
      user = generate(user()) |> ensure_workspace_plan()
      {:ok, folder} = Magus.Chat.create_folder(%{name: "Files", kind: :files}, actor: user)
      _file = generate(file(actor: user, folder_id: folder.id))
      reloaded = Magus.Chat.get_folder!(folder.id, actor: user)
      assert reloaded.kind == :files
    end

    test "file with no folder leaves other folders untouched" do
      user = generate(user()) |> ensure_workspace_plan()

      {:ok, sibling} =
        Magus.Chat.create_folder(%{name: "Sibling", kind: :conversations}, actor: user)

      file = generate(file(actor: user))
      assert is_nil(file.folder_id)

      reloaded = Magus.Chat.get_folder!(sibling.id, actor: user)
      assert reloaded.kind == :conversations
    end
  end

  describe "promote on file move_to_context" do
    test "moving file into a :conversations folder promotes it" do
      user = generate(user()) |> ensure_workspace_plan()

      {:ok, folder} =
        Magus.Chat.create_folder(%{name: "Chats", kind: :conversations}, actor: user)

      file = generate(file(actor: user))
      Magus.Files.move_file_to_context!(file, %{folder_id: folder.id}, actor: user)

      reloaded = Magus.Chat.get_folder!(folder.id, actor: user)
      assert reloaded.kind == :mixed
    end
  end

  describe "promote on conversation create" do
    test "conversation in :files folder promotes folder to :mixed" do
      user = generate(user())
      {:ok, folder} = Magus.Chat.create_folder(%{name: "Files", kind: :files}, actor: user)
      _conv = generate(conversation(actor: user, folder_id: folder.id))
      reloaded = Magus.Chat.get_folder!(folder.id, actor: user)
      assert reloaded.kind == :mixed
    end
  end

  describe "promote on conversation move_to_folder" do
    test "moving conversation into :files folder promotes it" do
      user = generate(user())
      {:ok, folder} = Magus.Chat.create_folder(%{name: "Files", kind: :files}, actor: user)
      conv = generate(conversation(actor: user))
      Magus.Chat.move_conversation_to_folder!(conv, %{folder_id: folder.id}, actor: user)
      reloaded = Magus.Chat.get_folder!(folder.id, actor: user)
      assert reloaded.kind == :mixed
    end
  end

  describe "no-op cases" do
    test "already :mixed stays :mixed" do
      user = generate(user())
      {:ok, folder} = Magus.Chat.create_folder(%{name: "Mix", kind: :files}, actor: user)
      Magus.Chat.promote_folder_to_mixed!(folder, actor: user)
      _conv = generate(conversation(actor: user, folder_id: folder.id))
      reloaded = Magus.Chat.get_folder!(folder.id, actor: user)
      assert reloaded.kind == :mixed
    end
  end
end
