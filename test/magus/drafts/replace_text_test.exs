defmodule Magus.Drafts.ReplaceTextTest do
  use Magus.ResourceCase, async: true

  alias Magus.Drafts
  alias Magus.Drafts.ProseMirrorConverter

  defp create_draft_with_content(content) do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
    {:ok, draft} = Drafts.create_draft(conversation.id, "Test", content, user.id, actor: user)
    %{user: user, draft: draft}
  end

  defp to_md(draft), do: ProseMirrorConverter.to_markdown(draft.content)

  describe "replace_draft_text/4 - single match" do
    test "replaces the only occurrence" do
      %{user: user, draft: draft} = create_draft_with_content("Hello world, this is a test.")

      {:ok, updated} =
        Drafts.replace_draft_text(draft, "world", "universe", nil, actor: user)

      assert to_md(updated) == "Hello universe, this is a test."
    end

    test "replaces multi-line old_text" do
      %{user: user, draft: draft} =
        create_draft_with_content("Line 1\n\nLine 2\n\nLine 3\n\nLine 4")

      {:ok, updated} =
        Drafts.replace_draft_text(draft, "Line 2\n\nLine 3", "New Line 2\n\nNew Line 3", nil,
          actor: user
        )

      assert to_md(updated) == "Line 1\n\nNew Line 2\n\nNew Line 3\n\nLine 4"
    end

    test "replacement can add paragraphs (expand document)" do
      %{user: user, draft: draft} = create_draft_with_content("A\n\nB\n\nC")

      {:ok, updated} =
        Drafts.replace_draft_text(draft, "B", "B1\n\nB2\n\nB3", nil, actor: user)

      assert to_md(updated) == "A\n\nB1\n\nB2\n\nB3\n\nC"
    end

    test "replacement can remove paragraphs (shrink document)" do
      %{user: user, draft: draft} = create_draft_with_content("A\n\nB\n\nC\n\nD\n\nE")

      {:ok, updated} =
        Drafts.replace_draft_text(draft, "B\n\nC\n\nD", "Merged", nil, actor: user)

      assert to_md(updated) == "A\n\nMerged\n\nE"
    end

    test "replacing with empty string deletes the text" do
      %{user: user, draft: draft} = create_draft_with_content("Hello world, this is a test.")

      {:ok, updated} =
        Drafts.replace_draft_text(draft, ", this is a test", "", nil, actor: user)

      assert to_md(updated) == "Hello world."
    end
  end

  describe "replace_draft_text/4 - no match" do
    test "returns error when text not found" do
      %{user: user, draft: draft} = create_draft_with_content("Hello world")

      assert {:error, _} =
               Drafts.replace_draft_text(draft, "nonexistent", "replacement", nil, actor: user)
    end
  end

  describe "replace_draft_text/5 - multiple matches with hint_line" do
    test "picks the occurrence closest to hint_line" do
      content = "foo bar\n\nsome text\n\nfoo bar\n\nmore text\n\nfoo bar"
      %{user: user, draft: draft} = create_draft_with_content(content)

      # hint_line=5 should match the second occurrence (line 5 in the markdown)
      {:ok, updated} =
        Drafts.replace_draft_text(draft, "foo bar", "REPLACED", 5, actor: user)

      assert to_md(updated) == "foo bar\n\nsome text\n\nREPLACED\n\nmore text\n\nfoo bar"
    end

    test "picks first occurrence when hint_line is 1" do
      content = "foo bar\n\nsome text\n\nfoo bar"
      %{user: user, draft: draft} = create_draft_with_content(content)

      {:ok, updated} =
        Drafts.replace_draft_text(draft, "foo bar", "REPLACED", 1, actor: user)

      assert to_md(updated) == "REPLACED\n\nsome text\n\nfoo bar"
    end

    test "picks last occurrence when hint_line is at end" do
      content = "foo bar\n\nsome text\n\nfoo bar"
      %{user: user, draft: draft} = create_draft_with_content(content)

      # "foo bar" at line 1, "some text" at line 3, "foo bar" at line 5
      {:ok, updated} =
        Drafts.replace_draft_text(draft, "foo bar", "REPLACED", 5, actor: user)

      assert to_md(updated) == "foo bar\n\nsome text\n\nREPLACED"
    end
  end

  describe "replace_draft_text/4 - multiple matches without hint_line" do
    test "returns error when multiple matches and no hint_line" do
      content = "foo bar\n\nsome text\n\nfoo bar"
      %{user: user, draft: draft} = create_draft_with_content(content)

      assert {:error, _} =
               Drafts.replace_draft_text(draft, "foo bar", "REPLACED", nil, actor: user)
    end
  end

  describe "version incrementing" do
    test "increments version on each replacement" do
      %{user: user, draft: draft} = create_draft_with_content("A\n\nB\n\nC")

      assert draft.version == 1

      {:ok, draft} = Drafts.replace_draft_text(draft, "A", "A2", nil, actor: user)
      assert draft.version == 2

      {:ok, draft} = Drafts.replace_draft_text(draft, "B", "B2", nil, actor: user)
      assert draft.version == 3
    end
  end
end
