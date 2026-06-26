defmodule Magus.LiveE2E.MemoryTest do
  @moduledoc """
  Tests for memory tool operations with real LLM.
  """
  use Magus.LiveE2ECase, async: false

  @moduletag :memory

  describe "set and recall memory" do
    @tag timeout: 240_000
    test "LLM sets a memory and recalls it in next turn", %{user: user, model: model} do
      conversation = create_conversation(user, model)
      subscribe_to_agent(conversation.id)

      # Turn 1: Ask LLM to save a memory
      send_user_message(
        conversation,
        user,
        "Use the set_memory tool to save a memory with name 'birthday' and summary 'My birthday is March 15th'."
      )

      assert_tool_started("set_memory")
      assert_tool_completed("set_memory")
      assert_response_complete()
      drain_signals()

      # Turn 2: Ask LLM to recall the memory
      send_user_message(
        conversation,
        user,
        "Use the search_memories tool to find what you know about my birthday."
      )

      assert_tool_started("search_memories")
      assert_tool_completed("search_memories")
      _payload = assert_response_complete()

      # Verify the response references the birthday
      message = latest_agent_message(conversation.id)
      assert message, "Expected agent message to be persisted"

      assert String.downcase(message.text) =~ "march" or
               String.downcase(message.text) =~ "15",
             "Expected response to reference birthday, got: #{message.text}"
    end
  end

  describe "forget memory" do
    @tag timeout: 240_000
    test "LLM forgets a previously set memory", %{user: user, model: model} do
      conversation = create_conversation(user, model)
      subscribe_to_agent(conversation.id)

      # Turn 1: Set a memory
      send_user_message(
        conversation,
        user,
        "Use set_memory to save a memory with name 'temp_note' and summary 'This is temporary'."
      )

      assert_tool_completed("set_memory")
      assert_response_complete()
      drain_signals()

      # Turn 2: Forget it
      send_user_message(
        conversation,
        user,
        "Use the forget_memory tool to delete the memory named 'temp_note'."
      )

      assert_tool_started("forget_memory")
      assert_tool_completed("forget_memory")
      assert_response_complete()
    end
  end
end
