defmodule Magus.LiveE2E.ChatTest do
  @moduledoc """
  Tests for basic chat flows with real LLM responses.
  """
  use Magus.LiveE2ECase, async: false

  @moduletag :chat

  describe "single message" do
    test "receives a non-empty response", %{user: user, model: model} do
      conversation = create_conversation(user, model)
      subscribe_to_agent(conversation.id)

      send_user_message(conversation, user, "What is 2 + 2? Answer briefly.")

      assert_response_complete()
    end
  end

  describe "multi-turn conversation" do
    test "maintains context across turns", %{user: user, model: model} do
      conversation = create_conversation(user, model)
      subscribe_to_agent(conversation.id)

      # Turn 1: Establish context
      send_user_message(
        conversation,
        user,
        "My favorite color is blue. Remember this. Reply with just 'OK, noted.'"
      )

      assert_response_complete()
      drain_signals()

      # Turn 2: Reference previous context
      send_user_message(
        conversation,
        user,
        "What is my favorite color? Reply with just the color name."
      )

      assert_response_complete()

      message = latest_agent_message(conversation.id)
      assert message, "Expected agent message to be persisted"

      assert String.downcase(message.text) =~ "blue",
             "Expected response to reference 'blue', got: #{message.text}"
    end
  end

  describe "system prompt" do
    test "inline system prompt influences response", %{user: user, model: model} do
      conversation =
        create_conversation(user, model,
          system_prompt:
            "You are a pirate. Always respond in pirate speak. Keep responses under 20 words."
        )

      subscribe_to_agent(conversation.id)

      send_user_message(conversation, user, "How are you today?")

      assert_response_complete()

      message = latest_agent_message(conversation.id)
      assert message, "Expected agent message to be persisted"
      text = String.downcase(message.text)

      assert text =~ ~r/ahoy|arr|matey|ye|sail|sea|treasure|captain|ship/,
             "Expected pirate-themed response, got: #{message.text}"
    end
  end
end
