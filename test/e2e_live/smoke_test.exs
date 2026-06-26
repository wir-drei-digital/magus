defmodule Magus.LiveE2E.SmokeTest do
  @moduledoc """
  Quick smoke tests to verify the live E2E infrastructure works.
  Run these first to validate API connectivity and pipeline health.

  Usage:
      mix test.e2e.live --only smoke
  """
  use Magus.LiveE2ECase, async: false

  @moduletag :smoke

  describe "basic pipeline" do
    test "send message and receive LLM response", %{user: user, model: model} do
      conversation = create_conversation(user, model)
      subscribe_to_agent(conversation.id)

      # Send a simple message through the full pipeline
      send_user_message(conversation, user, "Reply with exactly one word: hello")

      # Assert the response completes (full pipeline: SignalAgent → Dispatcher → Agent → LLM → PubSub)
      assert_response_complete()
    end

    test "response is persisted to database", %{user: user, model: model} do
      conversation = create_conversation(user, model)
      subscribe_to_agent(conversation.id)

      send_user_message(conversation, user, "Say hi in one short sentence.")

      # Wait for completion and get the message
      payload = assert_response_complete()
      message_id = payload[:message_id]

      if message_id do
        message = assert_valid_agent_message(message_id)
        assert String.length(message.text) > 0
      end
    end
  end
end
