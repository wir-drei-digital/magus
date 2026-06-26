defmodule Magus.LiveE2E.DraftTest do
  @moduledoc """
  Tests for draft mode tool operations with real LLM.
  """
  use Magus.LiveE2ECase, async: false

  @moduletag :draft
  @moduletag timeout: 240_000

  describe "draft creation" do
    test "LLM creates a draft via write_draft tool", %{user: user, model: model} do
      conversation = create_conversation(user, model)
      subscribe_to_agent(conversation.id)

      send_user_message(
        conversation,
        user,
        "Use the write_draft tool to create a new draft with title 'Meeting Notes' and content '# Meeting Notes\n\n- Discussed project timeline\n- Assigned tasks'. Set create_new to true."
      )

      assert_tool_started("write_draft")
      assert_tool_completed("write_draft")
      assert_response_complete()
    end
  end

  describe "draft read" do
    test "LLM reads a previously created draft", %{user: user, model: model} do
      conversation = create_conversation(user, model)
      subscribe_to_agent(conversation.id)

      # Turn 1: Create a draft
      send_user_message(
        conversation,
        user,
        "Use write_draft to create a draft titled 'Test Draft' with content 'Hello from the draft'. Set create_new to true."
      )

      assert_tool_completed("write_draft")
      assert_response_complete()
      drain_signals()

      # Turn 2: Read it back
      send_user_message(
        conversation,
        user,
        "Use the read_draft tool to load the draft we just created and tell me its content."
      )

      assert_tool_started("read_draft")
      assert_tool_completed("read_draft")
      assert_response_complete()
    end
  end
end
