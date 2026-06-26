defmodule Magus.Agents.Tools.Draft.ReadDraftTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Draft.ReadDraft
  alias Magus.Drafts

  defp create_test_context do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

    %{
      user: user,
      conversation: conversation,
      context: %{
        user_id: user.id,
        conversation_id: conversation.id
      }
    }
  end

  describe "display_name/0 and summarize_output/1" do
    test "provides display name" do
      assert ReadDraft.display_name() =~ "draft"
    end

    test "summarizes output with title" do
      assert ReadDraft.summarize_output(%{title: "Report", version: 2, line_count: 30}) =~
               "Report"
    end

    test "summarizes no draft" do
      assert ReadDraft.summarize_output(%{error: "No draft"}) =~ "No draft"
    end
  end

  describe "run/2" do
    test "reads draft with line numbers" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      content = "# Title\n\nParagraph one.\n\nParagraph two."

      {:ok, _draft} =
        Drafts.create_draft(conversation.id, "My Doc", content, user.id, actor: user)

      assert {:ok, result} = ReadDraft.run(%{}, context)
      assert result.title == "My Doc"
      assert result.version == 1
      assert result.line_count == 5

      # Content should have line numbers
      assert result.content =~ "1"
      assert result.content =~ "# Title"
      assert result.content =~ "5"
      assert result.content =~ "Paragraph two."
    end

    test "returns error when no draft exists" do
      %{context: context} = create_test_context()

      assert {:ok, result} = ReadDraft.run(%{}, context)
      assert result.error =~ "No draft"
    end

    test "returns error when context is missing" do
      assert {:ok, result} = ReadDraft.run(%{}, %{})
      assert result.error
    end
  end

  describe "run/2 - draft_id parameter" do
    test "reads specific draft by id" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      {:ok, _draft1} =
        Drafts.create_draft(conversation.id, "First", "Content 1", user.id, actor: user)

      {:ok, draft2} =
        Drafts.create_draft(conversation.id, "Second", "Content 2", user.id, actor: user)

      assert {:ok, result} = ReadDraft.run(%{"draft_id" => draft2.id}, context)
      assert result.title == "Second"
      assert result.draft_id == draft2.id
    end

    test "includes other_drafts when multiple exist" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      {:ok, _draft1} =
        Drafts.create_draft(conversation.id, "First", "Content 1", user.id, actor: user)

      {:ok, _draft2} =
        Drafts.create_draft(conversation.id, "Second", "Content 2", user.id, actor: user)

      # Read without draft_id — should return most recent and include other_drafts
      assert {:ok, result} = ReadDraft.run(%{}, context)
      assert result.title == "Second"
      assert length(result.other_drafts) == 1
      assert hd(result.other_drafts).title == "First"
    end
  end

  describe "run/2 - active_draft_id from context" do
    test "prefers active_draft_id from context" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      {:ok, draft1} =
        Drafts.create_draft(conversation.id, "First", "Content 1", user.id, actor: user)

      {:ok, _draft2} =
        Drafts.create_draft(conversation.id, "Second", "Content 2", user.id, actor: user)

      # Set active_draft_id to draft1 (not the most recent)
      context_with_active = Map.put(context, :active_draft_id, draft1.id)

      assert {:ok, result} = ReadDraft.run(%{}, context_with_active)
      assert result.title == "First"
      assert result.draft_id == draft1.id
    end

    test "explicit draft_id overrides active_draft_id" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      {:ok, draft1} =
        Drafts.create_draft(conversation.id, "First", "Content 1", user.id, actor: user)

      {:ok, draft2} =
        Drafts.create_draft(conversation.id, "Second", "Content 2", user.id, actor: user)

      # active_draft_id points to draft1, but explicit draft_id points to draft2
      context_with_active = Map.put(context, :active_draft_id, draft1.id)

      assert {:ok, result} = ReadDraft.run(%{"draft_id" => draft2.id}, context_with_active)
      assert result.title == "Second"
      assert result.draft_id == draft2.id
    end
  end
end
