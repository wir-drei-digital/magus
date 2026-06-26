defmodule Magus.LiveE2E.ToolCallingTest do
  @moduledoc """
  Tests for LLM tool calling with real API responses.
  Verifies the agentic loop: LLM decides to call tools, tools execute,
  results feed back to LLM for final response.
  """
  use Magus.LiveE2ECase, async: false

  @moduletag :tool_calling

  describe "tool search and dynamic loading" do
    @tag timeout: 240_000
    test "LLM discovers, loads, and uses a tool that is not preloaded", %{
      user: user,
      model: model
    } do
      conversation = create_conversation(user, model)
      subscribe_to_agent(conversation.id)

      # roll_dice is no longer in the base tool set; the agent must find it via
      # tool_search, enable it with load_tool, then call it.
      send_user_message(
        conversation,
        user,
        "Please roll a 6-sided dice and tell me the result."
      )

      assert_tool_started("tool_search")
      assert_tool_completed("tool_search")

      assert_tool_started("load_tool")
      assert_tool_completed("load_tool")

      assert_tool_started("roll_dice")
      assert_tool_completed("roll_dice")

      assert_response_complete()
    end

    @tag timeout: 240_000
    test "a loaded tool stays available on a later turn without re-searching", %{
      user: user,
      model: model
    } do
      conversation = create_conversation(user, model)
      subscribe_to_agent(conversation.id)

      send_user_message(conversation, user, "Please roll a 6-sided dice for me.")
      assert_tool_completed("roll_dice", 120_000)
      assert_response_complete()
      drain_signals()

      # Second turn: roll_dice is now persisted in loaded_tools, so the agent can
      # call it directly without another tool_search.
      send_user_message(conversation, user, "Roll it again.")
      assert_tool_completed("roll_dice", 120_000)
      assert_response_complete()
    end
  end

  describe "write_draft tool" do
    test "LLM writes a draft via tool", %{user: user, model: model} do
      conversation = create_conversation(user, model)
      subscribe_to_agent(conversation.id)

      send_user_message(
        conversation,
        user,
        "Use the write_draft tool to create a draft with title 'Shopping List' and content 'Buy milk and eggs'."
      )

      assert_tool_started("write_draft")
      assert_tool_completed("write_draft")
      assert_response_complete()
    end
  end

  describe "memory tools" do
    test "LLM sets and searches memories", %{user: user, model: model} do
      conversation = create_conversation(user, model)
      subscribe_to_agent(conversation.id)

      # Ask the LLM to set a memory
      send_user_message(
        conversation,
        user,
        "Use the set_memory tool to remember that my favorite animal is a penguin. Use key 'favorite_animal' and value 'penguin'."
      )

      assert_tool_started("set_memory")
      assert_tool_completed("set_memory")
      assert_response_complete()
      drain_signals()

      # Now ask to search memories
      send_user_message(
        conversation,
        user,
        "Use the search_memories tool to find what my favorite animal is. Search for 'favorite animal'."
      )

      assert_tool_started("search_memories")
      assert_tool_completed("search_memories")
      assert_response_complete()
    end
  end

  describe "multiple tools" do
    @tag timeout: 240_000
    test "LLM calls multiple tools in sequence", %{user: user, model: model} do
      conversation = create_conversation(user, model)
      subscribe_to_agent(conversation.id)

      send_user_message(
        conversation,
        user,
        "Please do two things: 1) Use set_memory to remember my favorite color is blue (key 'favorite_color', value 'blue'), 2) Write a draft titled 'Color Note' with the color using write_draft."
      )

      # Should see both tools execute (both are always-loaded base tools)
      assert_tool_completed("set_memory", 90_000)
      assert_tool_completed("write_draft", 90_000)
      assert_response_complete(120_000)
    end
  end
end
