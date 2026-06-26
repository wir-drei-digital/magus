defmodule Magus.Drafts.DraftTest do
  use Magus.ResourceCase, async: true

  alias Magus.Drafts
  alias Magus.Drafts.ProseMirrorConverter

  @ai_agent %Magus.Agents.Support.AiAgent{}

  defp to_md(draft), do: ProseMirrorConverter.to_markdown(draft.content)

  defp create_draft_context do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
    %{user: user, conversation: conversation}
  end

  describe "create_draft" do
    test "creates a draft for a conversation" do
      %{user: user, conversation: conversation} = create_draft_context()

      {:ok, draft} =
        Drafts.create_draft(
          conversation.id,
          "My Proposal",
          "# Proposal\n\nThis is the content.",
          user.id,
          actor: user
        )

      assert draft.title == "My Proposal"
      assert is_map(draft.content)
      assert to_md(draft) == "# Proposal\n\nThis is the content."
      assert draft.version == 1
      assert draft.status == :draft
      assert draft.conversation_id == conversation.id
      assert draft.user_id == user.id
    end

    test "AI agent can create a draft" do
      %{user: user, conversation: conversation} = create_draft_context()

      {:ok, draft} =
        Drafts.create_draft(
          conversation.id,
          "Agent Draft",
          "Content from agent",
          user.id,
          actor: @ai_agent
        )

      assert draft.title == "Agent Draft"
      assert draft.conversation_id == conversation.id
      assert draft.user_id == user.id
    end

    test "allows multiple drafts per conversation" do
      %{user: user, conversation: conversation} = create_draft_context()

      {:ok, draft1} =
        Drafts.create_draft(conversation.id, "First", "Content 1", user.id, actor: user)

      {:ok, draft2} =
        Drafts.create_draft(conversation.id, "Second", "Content 2", user.id, actor: user)

      assert draft1.id != draft2.id
      assert draft1.conversation_id == draft2.conversation_id
    end
  end

  describe "list_drafts_for_conversation" do
    test "returns drafts ordered by most recent first" do
      %{user: user, conversation: conversation} = create_draft_context()

      {:ok, _draft1} =
        Drafts.create_draft(conversation.id, "First", "Content 1", user.id, actor: user)

      {:ok, _draft2} =
        Drafts.create_draft(conversation.id, "Second", "Content 2", user.id, actor: user)

      {:ok, drafts} =
        Drafts.list_drafts_for_conversation(conversation.id, actor: user)

      assert length(drafts) == 2
      assert hd(drafts).title == "Second"
      assert List.last(drafts).title == "First"
    end

    test "returns empty list when no drafts exist" do
      %{user: user, conversation: conversation} = create_draft_context()

      {:ok, drafts} =
        Drafts.list_drafts_for_conversation(conversation.id, actor: user)

      assert drafts == []
    end
  end

  describe "get_draft_for_conversation" do
    test "returns most recent draft" do
      %{user: user, conversation: conversation} = create_draft_context()

      {:ok, _draft1} =
        Drafts.create_draft(conversation.id, "First", "Content 1", user.id, actor: user)

      {:ok, draft2} =
        Drafts.create_draft(conversation.id, "Second", "Content 2", user.id, actor: user)

      {:ok, found} =
        Drafts.get_draft_for_conversation(conversation.id, actor: user)

      assert found.id == draft2.id
      assert found.title == "Second"
    end

    test "returns nil when no draft exists" do
      %{user: user, conversation: conversation} = create_draft_context()

      assert {:ok, nil} =
               Drafts.get_draft_for_conversation(conversation.id, actor: user)
    end
  end

  describe "update_draft_content" do
    test "updates content and increments version" do
      %{user: user, conversation: conversation} = create_draft_context()

      {:ok, draft} =
        Drafts.create_draft(conversation.id, "Draft", "Original content", user.id, actor: user)

      assert draft.version == 1

      {:ok, updated} =
        Drafts.update_draft_content(draft, "Updated content", actor: user)

      assert to_md(updated) == "Updated content"
      assert updated.version == 2
    end

    test "multiple updates increment version correctly" do
      %{user: user, conversation: conversation} = create_draft_context()

      {:ok, draft} =
        Drafts.create_draft(conversation.id, "Draft", "v1", user.id, actor: user)

      {:ok, draft} = Drafts.update_draft_content(draft, "v2", actor: user)
      {:ok, draft} = Drafts.update_draft_content(draft, "v3", actor: user)

      assert draft.version == 3
      assert to_md(draft) == "v3"
    end
  end

  describe "update_draft_title" do
    test "updates the title" do
      %{user: user, conversation: conversation} = create_draft_context()

      {:ok, draft} =
        Drafts.create_draft(conversation.id, "Old Title", "Content", user.id, actor: user)

      {:ok, updated} = Drafts.update_draft_title(draft, "New Title", actor: user)
      assert updated.title == "New Title"
    end
  end

  describe "replace_draft_text" do
    test "replaces matching text" do
      %{user: user, conversation: conversation} = create_draft_context()
      content = "Line 1\n\nLine 2\n\nLine 3\n\nLine 4\n\nLine 5"

      {:ok, draft} =
        Drafts.create_draft(conversation.id, "Draft", content, user.id, actor: user)

      {:ok, updated} =
        Drafts.replace_draft_text(draft, "Line 2\n\nLine 3", "Replaced A\n\nReplaced B", nil,
          actor: user
        )

      assert to_md(updated) == "Line 1\n\nReplaced A\n\nReplaced B\n\nLine 4\n\nLine 5"
      assert updated.version == 2
    end

    test "replaces a single word" do
      %{user: user, conversation: conversation} = create_draft_context()
      content = "Line 1\n\nLine 2\n\nLine 3"

      {:ok, draft} =
        Drafts.create_draft(conversation.id, "Draft", content, user.id, actor: user)

      {:ok, updated} =
        Drafts.replace_draft_text(draft, "Line 2", "New Line 2", nil, actor: user)

      assert to_md(updated) == "Line 1\n\nNew Line 2\n\nLine 3"
    end

    test "returns error when text not found" do
      %{user: user, conversation: conversation} = create_draft_context()

      {:ok, draft} =
        Drafts.create_draft(conversation.id, "Draft", "Hello world", user.id, actor: user)

      {:error, _} =
        Drafts.replace_draft_text(draft, "nonexistent", "Too many", nil, actor: user)
    end

    test "returns error for ambiguous match without hint_line" do
      %{user: user, conversation: conversation} = create_draft_context()
      content = "foo\n\nbar\n\nfoo"

      {:ok, draft} =
        Drafts.create_draft(conversation.id, "Draft", content, user.id, actor: user)

      {:error, _} =
        Drafts.replace_draft_text(draft, "foo", "baz", nil, actor: user)
    end
  end

  describe "destroy_draft" do
    test "deletes a draft" do
      %{user: user, conversation: conversation} = create_draft_context()

      {:ok, draft} =
        Drafts.create_draft(conversation.id, "To Delete", "Content", user.id, actor: user)

      assert :ok = Drafts.destroy_draft(draft, actor: user)

      assert {:ok, nil} =
               Drafts.get_draft_for_conversation(conversation.id, actor: user)
    end

    test "only deletes targeted draft, not others" do
      %{user: user, conversation: conversation} = create_draft_context()

      {:ok, draft1} =
        Drafts.create_draft(conversation.id, "Keep", "Content 1", user.id, actor: user)

      {:ok, draft2} =
        Drafts.create_draft(conversation.id, "Delete", "Content 2", user.id, actor: user)

      assert :ok = Drafts.destroy_draft(draft2, actor: user)

      {:ok, drafts} =
        Drafts.list_drafts_for_conversation(conversation.id, actor: user)

      assert length(drafts) == 1
      assert hd(drafts).id == draft1.id
    end
  end

  describe "restore_draft_version" do
    test "restores content and title from a previous version" do
      %{user: user, conversation: conversation} = create_draft_context()

      {:ok, draft} =
        Drafts.create_draft(conversation.id, "Original Title", "Original content", user.id,
          actor: user
        )

      {:ok, draft} = Drafts.update_draft_content(draft, "Updated content", actor: user)
      assert draft.version == 2

      # Get the version from the create action (first version)
      {:ok, versions} = Magus.Drafts.list_draft_versions(draft.id, actor: user)
      create_version = Enum.find(versions, &(&1.version_action_name == :create))

      {:ok, restored} =
        Drafts.restore_draft_version(draft, create_version.id, actor: user)

      assert to_md(restored) == "Original content"
      assert restored.title == "Original Title"
    end

    test "increments version counter on restore" do
      %{user: user, conversation: conversation} = create_draft_context()

      {:ok, draft} =
        Drafts.create_draft(conversation.id, "Title", "v1", user.id, actor: user)

      {:ok, draft} = Drafts.update_draft_content(draft, "v2", actor: user)
      {:ok, draft} = Drafts.update_draft_content(draft, "v3", actor: user)
      assert draft.version == 3

      {:ok, versions} = Magus.Drafts.list_draft_versions(draft.id, actor: user)
      first_version = List.last(versions)

      {:ok, restored} =
        Drafts.restore_draft_version(draft, first_version.id, actor: user)

      assert restored.version == 4
    end

    test "creates a paper trail record for the restore action itself" do
      %{user: user, conversation: conversation} = create_draft_context()

      {:ok, draft} =
        Drafts.create_draft(conversation.id, "Title", "Original", user.id, actor: user)

      {:ok, draft} = Drafts.update_draft_content(draft, "Changed", actor: user)

      {:ok, versions_before} = Magus.Drafts.list_draft_versions(draft.id, actor: user)

      {:ok, _restored} =
        Drafts.restore_draft_version(draft, List.last(versions_before).id, actor: user)

      {:ok, versions_after} = Magus.Drafts.list_draft_versions(draft.id, actor: user)
      assert length(versions_after) == length(versions_before) + 1

      restore_version = hd(versions_after)
      assert restore_version.version_action_name == :restore_version
    end

    test "rejects version belonging to a different draft" do
      %{user: user, conversation: conversation} = create_draft_context()
      {:ok, conversation2} = Chat.create_conversation(%{}, actor: user)

      {:ok, draft1} =
        Drafts.create_draft(conversation.id, "Draft 1", "Content 1", user.id, actor: user)

      {:ok, draft2} =
        Drafts.create_draft(conversation2.id, "Draft 2", "Content 2", user.id, actor: user)

      {:ok, draft2_versions} = Magus.Drafts.list_draft_versions(draft2.id, actor: user)
      draft2_version = hd(draft2_versions)

      {:error, error} =
        Drafts.restore_draft_version(draft1, draft2_version.id, actor: user)

      assert_field_error(error, :version_id, "does not belong to this draft")
    end

    test "rejects non-existent version id" do
      %{user: user, conversation: conversation} = create_draft_context()

      {:ok, draft} =
        Drafts.create_draft(conversation.id, "Title", "Content", user.id, actor: user)

      fake_id = Ash.UUIDv7.generate()

      {:error, _} =
        Drafts.restore_draft_version(draft, fake_id, actor: user)
    end
  end

  describe "list_draft_versions" do
    test "returns versions in reverse chronological order" do
      %{user: user, conversation: conversation} = create_draft_context()

      {:ok, draft} =
        Drafts.create_draft(conversation.id, "Title", "v1", user.id, actor: user)

      {:ok, draft} = Drafts.update_draft_content(draft, "v2", actor: user)
      {:ok, _draft} = Drafts.update_draft_content(draft, "v3", actor: user)

      {:ok, versions} = Magus.Drafts.list_draft_versions(draft.id, actor: user)

      assert length(versions) == 3
      action_names = Enum.map(versions, & &1.version_action_name)
      assert hd(action_names) == :update_content
      assert List.last(action_names) == :create
    end
  end

  describe "authorization" do
    test "user cannot read another user's draft (returns nil due to policy filter)" do
      %{user: user1, conversation: conversation} = create_draft_context()
      user2 = generate(user())

      {:ok, _draft} =
        Drafts.create_draft(conversation.id, "Private", "Secret", user1.id, actor: user1)

      # Ash policy filters out records the user can't see, returning nil
      assert {:ok, nil} =
               Drafts.get_draft_for_conversation(conversation.id, actor: user2)
    end

    test "AI agent can read any draft" do
      %{user: user, conversation: conversation} = create_draft_context()

      {:ok, _draft} =
        Drafts.create_draft(conversation.id, "Draft", "Content", user.id, actor: user)

      {:ok, found} =
        Drafts.get_draft_for_conversation(conversation.id, actor: @ai_agent)

      assert found.title == "Draft"
    end
  end
end
