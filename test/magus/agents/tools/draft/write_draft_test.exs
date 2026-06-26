defmodule Magus.Agents.Tools.Draft.WriteDraftTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Draft.WriteDraft
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
      assert WriteDraft.display_name() =~ "draft"
    end

    test "summarizes created output" do
      assert WriteDraft.summarize_output(%{mode: "created", title: "Proposal"}) =~
               "Proposal"
    end

    test "summarizes updated output" do
      assert WriteDraft.summarize_output(%{mode: "updated", title: "Report"}) =~
               "Report"
    end

    test "summarizes edited_text output" do
      assert WriteDraft.summarize_output(%{mode: "edited_text"}) == "Edited text"
    end

    test "summarizes error output" do
      assert WriteDraft.summarize_output(%{error: "Not found"}) == "Error"
    end
  end

  describe "run/2 - full mode (create)" do
    test "creates a new draft" do
      %{context: context} = create_test_context()

      params = %{
        "title" => "Business Proposal",
        "content" => "# Proposal\n\nExecutive summary here."
      }

      assert {:ok, result} = WriteDraft.run(params, context)
      assert result.mode == "created"
      assert result.title == "Business Proposal"
      assert result.version == 1
      assert result.line_count == 3
      assert result.draft_id
    end

    test "updates existing draft with full content" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      {:ok, _draft} =
        Drafts.create_draft(conversation.id, "Old Title", "Old content", user.id, actor: user)

      params = %{
        "title" => "New Title",
        "content" => "Completely new content\n\nWith two paragraphs"
      }

      assert {:ok, result} = WriteDraft.run(params, context)
      assert result.mode == "updated"
      assert result.title == "New Title"
      assert result.version == 2
      assert result.line_count == 3
    end
  end

  describe "run/2 - surgical mode (text replacement)" do
    test "replaces matching text" do
      %{user: user, conversation: conversation, context: context} = create_test_context()
      content = "Line 1\n\nLine 2\n\nLine 3\n\nLine 4\n\nLine 5"

      {:ok, _draft} =
        Drafts.create_draft(conversation.id, "Draft", content, user.id, actor: user)

      params = %{
        "title" => "Draft",
        "content" => "New Line 2\n\nNew Line 3",
        "old_text" => "Line 2\n\nLine 3"
      }

      assert {:ok, result} = WriteDraft.run(params, context)
      assert result.mode == "edited_text"
      assert result.version == 2
    end

    test "surgical edit with hint_line disambiguates duplicates" do
      %{user: user, conversation: conversation, context: context} = create_test_context()
      content = "foo bar\n\nsome text\n\nfoo bar"

      {:ok, _draft} =
        Drafts.create_draft(conversation.id, "Draft", content, user.id, actor: user)

      params = %{
        "title" => "Draft",
        "content" => "REPLACED",
        "old_text" => "foo bar",
        "hint_line" => 5
      }

      assert {:ok, result} = WriteDraft.run(params, context)
      assert result.mode == "edited_text"
    end

    test "returns error when no draft exists for surgical edit" do
      %{context: context} = create_test_context()

      params = %{
        "title" => "Draft",
        "content" => "New text",
        "old_text" => "some old text"
      }

      assert {:ok, result} = WriteDraft.run(params, context)
      assert result.error =~ "No draft"
    end

    test "returns error when old_text not found" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      {:ok, _draft} =
        Drafts.create_draft(conversation.id, "Draft", "Hello world", user.id, actor: user)

      params = %{
        "title" => "Draft",
        "content" => "replacement",
        "old_text" => "nonexistent text"
      }

      assert {:ok, result} = WriteDraft.run(params, context)
      assert result.error =~ "text not found"
    end
  end

  describe "run/2 - create_new parameter" do
    test "creates a new draft even when one exists" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      {:ok, _draft} =
        Drafts.create_draft(conversation.id, "Existing", "Content", user.id, actor: user)

      params = %{
        "title" => "Brand New",
        "content" => "Totally different document",
        "create_new" => true
      }

      assert {:ok, result} = WriteDraft.run(params, context)
      assert result.mode == "created"
      assert result.title == "Brand New"

      # Verify both drafts exist
      {:ok, drafts} =
        Drafts.list_drafts_for_conversation(conversation.id,
          actor: %Magus.Agents.Support.AiAgent{}
        )

      assert length(drafts) == 2
    end
  end

  describe "run/2 - draft_id parameter" do
    test "updates a specific draft by id" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      {:ok, draft1} =
        Drafts.create_draft(conversation.id, "First", "Content 1", user.id, actor: user)

      {:ok, _draft2} =
        Drafts.create_draft(conversation.id, "Second", "Content 2", user.id, actor: user)

      params = %{
        "title" => "First Updated",
        "content" => "Updated content for first draft",
        "draft_id" => draft1.id
      }

      assert {:ok, result} = WriteDraft.run(params, context)
      assert result.mode == "updated"
      assert result.draft_id == draft1.id
      assert result.title == "First Updated"
    end

    test "surgical edit on specific draft by id" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      {:ok, draft1} =
        Drafts.create_draft(conversation.id, "First", "Hello world", user.id, actor: user)

      {:ok, _draft2} =
        Drafts.create_draft(conversation.id, "Second", "Goodbye world", user.id, actor: user)

      params = %{
        "title" => "First",
        "content" => "universe",
        "old_text" => "world",
        "draft_id" => draft1.id
      }

      assert {:ok, result} = WriteDraft.run(params, context)
      assert result.mode == "edited_text"
      assert result.draft_id == draft1.id
    end
  end

  describe "run/2 - active_draft_id from context" do
    test "prefers active_draft_id over most recent" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      {:ok, draft1} =
        Drafts.create_draft(conversation.id, "First", "Content 1", user.id, actor: user)

      {:ok, _draft2} =
        Drafts.create_draft(conversation.id, "Second", "Content 2", user.id, actor: user)

      context_with_active = Map.put(context, :active_draft_id, draft1.id)

      params = %{
        "title" => "First Updated",
        "content" => "Updated via active draft"
      }

      assert {:ok, result} = WriteDraft.run(params, context_with_active)
      assert result.mode == "updated"
      assert result.draft_id == draft1.id
    end

    test "explicit draft_id overrides active_draft_id" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      {:ok, draft1} =
        Drafts.create_draft(conversation.id, "First", "Content 1", user.id, actor: user)

      {:ok, draft2} =
        Drafts.create_draft(conversation.id, "Second", "Content 2", user.id, actor: user)

      context_with_active = Map.put(context, :active_draft_id, draft1.id)

      params = %{
        "title" => "Second Updated",
        "content" => "Updated via explicit id",
        "draft_id" => draft2.id
      }

      assert {:ok, result} = WriteDraft.run(params, context_with_active)
      assert result.mode == "updated"
      assert result.draft_id == draft2.id
    end
  end

  describe "run/2 - error handling" do
    test "returns error when context is missing" do
      params = %{"title" => "Test", "content" => "Content"}
      assert {:ok, result} = WriteDraft.run(params, %{})
      assert result.error
    end
  end
end
