defmodule Magus.Agents.Context.DraftContextTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Context.DraftContext
  alias Magus.Drafts

  defp create_draft_context do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
    %{user: user, conversation: conversation}
  end

  describe "build/2 - single draft" do
    test "returns nil when no draft exists" do
      %{conversation: conversation} = create_draft_context()
      assert DraftContext.build(conversation.id) == nil
    end

    test "returns context string when draft exists" do
      %{user: user, conversation: conversation} = create_draft_context()

      {:ok, _draft} =
        Drafts.create_draft(
          conversation.id,
          "Business Proposal",
          "# Proposal\n\nContent here.\n\nMore content.",
          user.id,
          actor: user
        )

      result = DraftContext.build(conversation.id, nil, actor: user)

      assert result =~ "## Active Draft"
      assert result =~ "Business Proposal"
      assert result =~ "Version:** 1 (5 lines)"
      assert result =~ "read_draft"
      assert result =~ "write_draft"
      assert result =~ "create_new: true"
    end

    test "returns nil for nil input" do
      assert DraftContext.build(nil) == nil
    end

    test "returns nil for non-binary input" do
      assert DraftContext.build(123) == nil
    end

    test "reflects updated version and line count" do
      %{user: user, conversation: conversation} = create_draft_context()

      {:ok, draft} =
        Drafts.create_draft(conversation.id, "Doc", "Line 1\n\nLine 2", user.id, actor: user)

      {:ok, _updated} =
        Drafts.update_draft_content(draft, "Line 1\n\nLine 2\n\nLine 3\n\nLine 4\n\nLine 5",
          actor: user
        )

      result = DraftContext.build(conversation.id, nil, actor: user)
      assert result =~ "Version:** 2 (9 lines)"
    end
  end

  describe "build/2 - multiple drafts" do
    test "returns multi-draft context with numbered list" do
      %{user: user, conversation: conversation} = create_draft_context()

      {:ok, _draft1} =
        Drafts.create_draft(conversation.id, "Report A", "Content A", user.id, actor: user)

      {:ok, _draft2} =
        Drafts.create_draft(conversation.id, "Report B", "Content B", user.id, actor: user)

      result = DraftContext.build(conversation.id, nil, actor: user)

      assert result =~ "## Drafts"
      assert result =~ "2 draft documents"
      assert result =~ "Report A"
      assert result =~ "Report B"
      assert result =~ "draft_id"
    end

    test "marks the active draft" do
      %{user: user, conversation: conversation} = create_draft_context()

      {:ok, draft1} =
        Drafts.create_draft(conversation.id, "Report A", "Content A", user.id, actor: user)

      {:ok, _draft2} =
        Drafts.create_draft(conversation.id, "Report B", "Content B", user.id, actor: user)

      result = DraftContext.build(conversation.id, draft1.id, actor: user)

      assert result =~ "[ACTIVE]"
      assert result =~ "Report A"
    end

    test "shows draft ids for non-active drafts" do
      %{user: user, conversation: conversation} = create_draft_context()

      {:ok, draft1} =
        Drafts.create_draft(conversation.id, "Report A", "Content A", user.id, actor: user)

      {:ok, draft2} =
        Drafts.create_draft(conversation.id, "Report B", "Content B", user.id, actor: user)

      result = DraftContext.build(conversation.id, draft1.id, actor: user)

      # draft1 should be [ACTIVE], draft2 should show id
      assert result =~ "[ACTIVE]"
      assert result =~ "id: #{draft2.id}"
    end
  end
end
