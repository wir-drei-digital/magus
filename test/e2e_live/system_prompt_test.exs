defmodule Magus.LiveE2E.SystemPromptTest do
  @moduledoc """
  Tests for system prompt activation with real LLM.
  Verifies that system prompts influence the AI's behavior.
  """
  use Magus.LiveE2ECase, async: false

  @moduletag :system_prompt

  describe "brain prompt activation" do
    test "activated system prompt influences response", %{user: user, model: model} do
      # Create a system prompt in the library
      {:ok, prompt} =
        Library.create_prompt(
          %{
            name: "French Chef",
            content:
              "You are a French chef. Always respond in a French accent and mention cooking. Keep responses under 30 words.",
            type: :system
          },
          actor: user
        )

      # Create conversation and activate the prompt
      conversation = create_conversation(user, model)

      {:ok, conversation} =
        Chat.activate_system_prompt(conversation, prompt.id, actor: user)

      subscribe_to_agent(conversation.id)

      send_user_message(conversation, user, "How are you today?")

      assert_response_complete()

      message = latest_agent_message(conversation.id)
      assert message, "Expected agent message to be persisted"
      text = String.downcase(message.text)

      assert text =~ ~r/cook|chef|cuisine|recipe|kitchen|bon|oui|magnifique|voila|french/,
             "Expected French chef themed response, got: #{message.text}"
    end
  end

  describe "prompt deactivation" do
    test "deactivated prompt no longer influences response", %{user: user, model: model} do
      # Create and activate a system prompt
      {:ok, prompt} =
        Library.create_prompt(
          %{
            name: "Robot",
            content: "You are a robot. Always say BEEP BOOP in your response.",
            type: :system
          },
          actor: user
        )

      conversation = create_conversation(user, model)
      {:ok, conversation} = Chat.activate_system_prompt(conversation, prompt.id, actor: user)

      # Now deactivate it
      {:ok, _conversation} = Chat.deactivate_system_prompt(conversation, actor: user)

      subscribe_to_agent(conversation.id)

      send_user_message(conversation, user, "Say hello in one sentence.")

      assert_response_complete()

      message = latest_agent_message(conversation.id)
      assert message, "Expected agent message to be persisted"
      # After deactivation, response should NOT contain robot speak
      refute String.contains?(String.upcase(message.text), "BEEP BOOP"),
             "Expected non-robot response after deactivation, got: #{message.text}"
    end
  end
end
