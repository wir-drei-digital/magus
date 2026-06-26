defmodule Magus.Chat.ConversationTest do
  use Magus.ResourceCase, async: true
  use Oban.Testing, repo: Magus.Repo

  require Ash.Query

  alias Magus.Chat

  describe "create/1" do
    test "creates conversation with valid attributes" do
      user = generate(user())

      {:ok, conversation} =
        Chat.create_conversation(%{title: "Test Conversation"}, actor: user)

      assert conversation.title == "Test Conversation"
      assert conversation.user_id == user.id
      assert conversation.chat_mode == :chat
      assert conversation.is_multiplayer == false
    end

    test "creates conversation with specific chat mode" do
      user = generate(user())

      {:ok, conversation} =
        Chat.create_conversation(%{chat_mode: :image_generation}, actor: user)

      assert conversation.chat_mode == :image_generation
    end

    test "creates conversation without title" do
      user = generate(user())

      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      assert conversation.title == nil
    end

    test "creates conversation in a folder" do
      user = generate(user())
      folder = generate(folder(actor: user))

      {:ok, conversation} =
        Chat.create_conversation(%{folder_id: folder.id}, actor: user)

      assert conversation.folder_id == folder.id
    end

    test "creates conversation with skill_tools" do
      user = generate(user())

      {:ok, conversation} =
        Chat.create_conversation(
          %{skill_tools: ["web_search", "web_fetch"]},
          actor: user
        )

      assert conversation.skill_tools == ["web_search", "web_fetch"]
    end

    test "creates conversation with skill_context and skill_tools" do
      user = generate(user())

      {:ok, conversation} =
        Chat.create_conversation(
          %{
            skill_context: "# Test Wizard\nSome instructions",
            skill_tools: ["web_search"]
          },
          actor: user
        )

      assert conversation.skill_context =~ "Test Wizard"
      assert conversation.skill_tools == ["web_search"]
    end

    test "creates conversation with nil skill_tools by default" do
      user = generate(user())

      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      assert conversation.skill_tools == nil
    end
  end

  describe "set_mode/1" do
    test "updates chat_mode" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, updated} =
        Chat.set_conversation_mode(conversation, %{chat_mode: :reasoning}, actor: user)

      assert updated.chat_mode == :reasoning
    end
  end

  describe "rename/1" do
    test "updates title" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{title: "Old Title"}, actor: user)

      {:ok, updated} =
        Chat.rename_conversation(conversation, %{title: "New Title"}, actor: user)

      assert updated.title == "New Title"
    end
  end

  describe "move_to_folder/1" do
    test "moves conversation to folder" do
      user = generate(user())
      folder = generate(folder(actor: user))
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, updated} =
        Chat.move_conversation_to_folder(conversation, %{folder_id: folder.id}, actor: user)

      assert updated.folder_id == folder.id
    end

    test "moves conversation out of folder" do
      user = generate(user())
      folder = generate(folder(actor: user))
      {:ok, conversation} = Chat.create_conversation(%{folder_id: folder.id}, actor: user)

      {:ok, updated} =
        Chat.move_conversation_to_folder(conversation, %{folder_id: nil}, actor: user)

      assert updated.folder_id == nil
    end
  end

  describe "enable_multiplayer/1" do
    test "sets is_multiplayer to true" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, updated} = Chat.enable_multiplayer(conversation, actor: user)

      assert updated.is_multiplayer == true
    end
  end

  describe "update_visibility/1" do
    test "changes visibility to public" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, updated} =
        Chat.update_conversation_visibility(conversation, %{visibility: :public}, actor: user)

      assert updated.visibility == :public
    end

    test "changes visibility to invite_only" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      # First set to public
      {:ok, _} =
        Chat.update_conversation_visibility(conversation, %{visibility: :public}, actor: user)

      {:ok, updated} =
        Chat.update_conversation_visibility(conversation, %{visibility: :invite_only},
          actor: user
        )

      assert updated.visibility == :invite_only
    end
  end

  describe "set_model/1" do
    test "sets conversation model" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
      model = generate(model())

      {:ok, updated} =
        Chat.set_conversation_model(conversation, %{selected_model_id: model.id}, actor: user)

      assert updated.selected_model_id == model.id
    end
  end

  describe "delete_full_conversation/1" do
    test "deletes conversation" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      :ok = Chat.delete_full_conversation(conversation, actor: user)

      {:error, _} = Chat.get_conversation(conversation.id, actor: user)
    end
  end

  describe "activate_system_prompt/2" do
    test "sets system_prompt_id on conversation" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
      prompt = generate(prompt(actor: user))

      {:ok, updated} =
        Chat.activate_system_prompt(conversation, prompt.id, actor: user)

      assert updated.system_prompt_id == prompt.id
    end

    test "applies prompt's model when set" do
      user = generate(user())
      model = generate(model())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
      prompt = generate(prompt(actor: user, model_id: model.id))

      {:ok, updated} =
        Chat.activate_system_prompt(conversation, prompt.id, actor: user)

      assert updated.system_prompt_id == prompt.id
      assert updated.selected_model_id == model.id
    end

    test "applies prompt's chat_mode when set" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
      prompt = generate(prompt(actor: user, chat_mode: :reasoning))

      {:ok, updated} =
        Chat.activate_system_prompt(conversation, prompt.id, actor: user)

      assert updated.system_prompt_id == prompt.id
      assert updated.chat_mode == :reasoning
    end

    test "applies both model and chat_mode when both set" do
      user = generate(user())
      model = generate(model())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
      prompt = generate(prompt(actor: user, model_id: model.id, chat_mode: :search))

      {:ok, updated} =
        Chat.activate_system_prompt(conversation, prompt.id, actor: user)

      assert updated.system_prompt_id == prompt.id
      assert updated.selected_model_id == model.id
      assert updated.chat_mode == :search
    end

    test "does not change model or mode when prompt has neither set" do
      user = generate(user())
      model = generate(model())

      {:ok, conversation} =
        Chat.create_conversation(%{chat_mode: :reasoning}, actor: user)

      {:ok, conversation} =
        Chat.set_conversation_model(conversation, %{selected_model_id: model.id}, actor: user)

      prompt = generate(prompt(actor: user))

      {:ok, updated} =
        Chat.activate_system_prompt(conversation, prompt.id, actor: user)

      assert updated.system_prompt_id == prompt.id
      assert updated.selected_model_id == model.id
      assert updated.chat_mode == :reasoning
    end
  end

  describe "policies" do
    test "owner can read their conversation" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, found} = Chat.get_conversation(conversation.id, actor: user)
      assert found.id == conversation.id
    end

    test "non-owner cannot read conversation" do
      owner = generate(user())
      other = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      # Ash returns NotFound instead of Forbidden to prevent information leakage
      {:error, %Ash.Error.Invalid{}} = Chat.get_conversation(conversation.id, actor: other)
    end

    test "owner can update conversation" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      assert Chat.can_rename_conversation?(user, conversation)
    end

    test "non-owner cannot update conversation" do
      owner = generate(user())
      other = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      refute Chat.can_rename_conversation?(other, conversation)
    end

    test "owner can delete conversation" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      assert Chat.can_delete_full_conversation?(user, conversation)
    end
  end

  describe "workspace_favorite_conversations / personal_favorite_conversations" do
    test "personal_favorite_conversations returns only no-workspace favorites" do
      user = generate(user())
      ensure_workspace_plan(user)
      workspace = generate(workspace(actor: user))

      personal = Chat.create_conversation!(%{title: "p"}, actor: user)
      in_ws = Chat.create_conversation!(%{title: "w", workspace_id: workspace.id}, actor: user)

      Chat.create_conversation_favorite!(%{conversation_id: personal.id}, actor: user)
      Chat.create_conversation_favorite!(%{conversation_id: in_ws.id}, actor: user)

      ids = Chat.personal_favorite_conversations!(actor: user) |> Enum.map(& &1.id)
      assert personal.id in ids
      refute in_ws.id in ids
    end

    test "workspace_favorite_conversations returns only that workspace's favorites" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws_a = generate(workspace(actor: user))
      ws_b = generate(workspace(actor: user))

      in_a = Chat.create_conversation!(%{title: "a", workspace_id: ws_a.id}, actor: user)
      in_b = Chat.create_conversation!(%{title: "b", workspace_id: ws_b.id}, actor: user)
      no_ws = Chat.create_conversation!(%{title: "p"}, actor: user)

      Chat.create_conversation_favorite!(%{conversation_id: in_a.id}, actor: user)
      Chat.create_conversation_favorite!(%{conversation_id: in_b.id}, actor: user)
      Chat.create_conversation_favorite!(%{conversation_id: no_ws.id}, actor: user)

      ids = Chat.workspace_favorite_conversations!(ws_a.id, actor: user) |> Enum.map(& &1.id)
      assert in_a.id in ids
      refute in_b.id in ids
      refute no_ws.id in ids
    end
  end

  describe ":my_conversations excludes companion-linked conversations" do
    test "regular conversation appears" do
      user = generate(user())
      {:ok, conv} = Magus.Chat.create_conversation(%{title: "Plain"}, actor: user)

      assert {:ok, list} =
               Magus.Chat.Conversation
               |> Ash.Query.for_read(:my_conversations, %{}, actor: user)
               |> Ash.read()

      assert Enum.any?(list, &(&1.id == conv.id))
    end

    test "companion-linked conversation does not appear" do
      user = generate(user())
      ws = generate(workspace(actor: user))
      ensure_workspace_plan(user)

      {:ok, file} =
        Magus.Files.create_file(
          %{
            name: "x.pdf",
            type: :document,
            mime_type: "application/pdf",
            file_size: 1,
            file_path: "#{user.id}/#{Ash.UUIDv7.generate()}.pdf",
            workspace_id: ws.id
          },
          actor: user
        )

      {:ok, companion} =
        Magus.Chat.find_or_create_companion_conversation(:file, file.id, actor: user)

      {:ok, list} =
        Magus.Chat.Conversation
        |> Ash.Query.for_read(:my_conversations, %{}, actor: user)
        |> Ash.read()

      refute Enum.any?(list, &(&1.id == companion.id))
    end
  end

  describe "companion conversations excluded from all list reads" do
    test "every filtered list read excludes the linked conversation" do
      user = generate(user())
      ws = generate(workspace(actor: user))
      ensure_workspace_plan(user)

      # Workspace-scoped companion: passes workspace_id == ws.id and the
      # workspace_favorites/workspace_conversations/my_conversations conditions
      # if not for the new is_nil(companion_link.id) clause.
      {:ok, ws_file} =
        Magus.Files.create_file(
          %{
            name: "ws.pdf",
            type: :document,
            mime_type: "application/pdf",
            file_size: 1,
            file_path: "#{user.id}/#{Ash.UUIDv7.generate()}.pdf",
            workspace_id: ws.id
          },
          actor: user
        )

      {:ok, ws_companion} =
        Magus.Chat.find_or_create_companion_conversation(:file, ws_file.id, actor: user)

      # Personal companion: workspace_id is nil, so it would qualify for
      # personal_conversations / personal_favorites / unfiled_conversations
      # if not for the new is_nil(companion_link.id) clause.
      {:ok, personal_file} =
        Magus.Files.create_file(
          %{
            name: "personal.pdf",
            type: :document,
            mime_type: "application/pdf",
            file_size: 1,
            file_path: "#{user.id}/#{Ash.UUIDv7.generate()}.pdf"
          },
          actor: user
        )

      {:ok, personal_companion} =
        Magus.Chat.find_or_create_companion_conversation(:file, personal_file.id, actor: user)

      # Favorite both so the favorites filters are actually exercised.
      Chat.create_conversation_favorite!(%{conversation_id: ws_companion.id}, actor: user)
      Chat.create_conversation_favorite!(%{conversation_id: personal_companion.id}, actor: user)

      # Each assertion targets the companion that would otherwise pass the
      # action's *other* clauses, so a missing is_nil(companion_link.id)
      # clause causes the assertion to fail.

      # :my_conversations excludes both
      assert_excluded(:my_conversations, %{}, [ws_companion.id, personal_companion.id], user)

      # :my_favorites excludes both (both are favorited)
      assert_excluded(:my_favorites, %{}, [ws_companion.id, personal_companion.id], user)

      # :personal_favorites: personal-scoped + favorited -> personal_companion would qualify
      assert_excluded(:personal_favorites, %{}, [personal_companion.id], user)

      # :workspace_favorites: workspace-scoped + favorited -> ws_companion would qualify
      assert_excluded(:workspace_favorites, %{workspace_id: ws.id}, [ws_companion.id], user)

      # :unfiled_conversations: workspace_id == nil -> personal_companion would qualify
      assert_excluded(:unfiled_conversations, %{}, [personal_companion.id], user)

      # :workspace_conversations: workspace_id matches -> ws_companion would qualify
      assert_excluded(:workspace_conversations, %{workspace_id: ws.id}, [ws_companion.id], user)

      # :personal_conversations: workspace_id == nil -> personal_companion would qualify
      assert_excluded(:personal_conversations, %{}, [personal_companion.id], user)
    end

    test "personal_conversations excludes agent-spawned task conversations" do
      user = generate(user())
      regular = generate(conversation(actor: user))

      task =
        generate(
          conversation(
            actor: user,
            is_task_conversation: true,
            parent_conversation_id: regular.id
          )
        )

      {:ok, list} =
        Magus.Chat.Conversation
        |> Ash.Query.for_read(:personal_conversations, %{}, actor: user)
        |> Ash.read()

      ids = Enum.map(list, & &1.id)
      assert regular.id in ids
      refute task.id in ids
    end
  end

  describe "filed_conversations/0" do
    test "includes conversations that live in a folder and excludes unfiled ones" do
      user = generate(user())
      folder = generate(folder(actor: user))
      filed = generate(conversation(actor: user, folder_id: folder.id))
      unfiled = generate(conversation(actor: user))

      ids = Chat.filed_conversations!(actor: user) |> Enum.map(& &1.id)

      assert filed.id in ids
      refute unfiled.id in ids
    end

    test "is not capped at the unfiled limit (folders keep all their conversations)" do
      user = generate(user())
      folder = generate(folder(actor: user))

      for i <- 1..25,
          do: generate(conversation(actor: user, folder_id: folder.id, title: "f#{i}"))

      assert length(Chat.filed_conversations!(actor: user)) == 25
    end
  end

  defp assert_excluded(action, args, expected_excluded_ids, user) do
    {:ok, list} =
      Magus.Chat.Conversation
      |> Ash.Query.for_read(action, args, actor: user)
      |> Ash.read()

    listed_ids = Enum.map(list, & &1.id)

    for id <- expected_excluded_ids do
      refute id in listed_ids, "#{action} unexpectedly included #{id}"
    end
  end
end
