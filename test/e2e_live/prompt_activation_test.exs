defmodule Magus.LiveE2E.PromptActivationTest do
  @moduledoc """
  Tests for brain prompt activation with model/mode presets.
  """
  use Magus.LiveE2ECase, async: false

  @moduletag :prompt_activation

  describe "prompt with presets" do
    test "activating prompt applies model preset and responds", %{user: user, model: model} do
      # Create a system prompt with a model preset
      {:ok, prompt} =
        Library.create_prompt(
          %{
            name: "Concise Assistant",
            content: "You are extremely concise. Never use more than 10 words in a response.",
            type: :system,
            model_id: model.id
          },
          actor: user
        )

      conversation = create_conversation(user, model)

      # Activate prompt — this should apply model preset
      {:ok, conversation} =
        Chat.activate_system_prompt(conversation, prompt.id, actor: user)

      assert conversation.system_prompt_id == prompt.id

      subscribe_to_agent(conversation.id)

      send_user_message(conversation, user, "What is the meaning of life?")

      assert_response_complete()

      message = latest_agent_message(conversation.id)
      assert message, "Expected agent message to be persisted"
      # Response should be concise due to system prompt
      word_count = message.text |> String.split() |> length()

      assert word_count <= 30,
             "Expected concise response (<= 30 words), got #{word_count} words: #{message.text}"
    end
  end
end
