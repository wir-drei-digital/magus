defmodule Magus.Chat.MessagePropertyTest do
  @moduledoc """
  Property-based tests for Message resource.

  Uses StreamData to verify that message creation handles
  a variety of valid inputs correctly.
  """
  use Magus.ResourceCase, async: true
  use ExUnitProperties

  import Magus.PropertyGenerators

  alias Magus.Chat

  describe "message creation" do
    property "accepts any valid message content" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      check all(content <- message_content(), max_runs: 25) do
        {:ok, message} =
          Chat.send_user_message(
            %{text: content, conversation_id: conversation.id},
            actor: user
          )

        assert message.text == content
        assert message.source == :user
        assert message.conversation_id == conversation.id
      end
    end

    property "accepts all valid message modes" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      check all(mode <- chat_mode(), max_runs: 10) do
        {:ok, message} =
          Chat.send_user_message(
            %{text: "Test message", conversation_id: conversation.id, mode: mode},
            actor: user
          )

        assert message.mode == mode
      end
    end
  end
end
