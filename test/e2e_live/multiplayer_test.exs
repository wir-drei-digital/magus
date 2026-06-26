defmodule Magus.LiveE2E.MultiplayerTest do
  @moduledoc """
  Tests for multiplayer conversation flows with real LLM.
  """
  use Magus.LiveE2ECase, async: false

  @moduletag :multiplayer
  @moduletag timeout: 240_000

  describe "multiplayer conversation" do
    test "owner can send messages in multiplayer conversation", %{user: owner, model: model} do
      # Create multiplayer conversation with a member
      member = create_live_user()
      setup_live_subscription(member)

      conversation = create_conversation(owner, model)
      {:ok, conversation} = Chat.enable_multiplayer(conversation, actor: owner)

      {:ok, _membership} =
        Chat.add_conversation_member(
          conversation.id,
          member.id,
          %{role: :member},
          authorize?: false
        )

      subscribe_to_agent(conversation.id)

      # Owner sends a message — agent should respond normally
      send_user_message(
        conversation,
        owner,
        "I am the owner of a multiplayer conversation. Say 'Hello owner' in one sentence."
      )

      assert_response_complete()

      message = latest_agent_message(conversation.id)
      assert message, "Expected agent message to be persisted"
    end
  end

  describe "observer role" do
    test "observer cannot send messages", %{user: owner, model: model} do
      observer = create_live_user()
      setup_live_subscription(observer)

      conversation = create_conversation(owner, model)
      {:ok, conversation} = Chat.enable_multiplayer(conversation, actor: owner)

      {:ok, _membership} =
        Chat.add_conversation_member(
          conversation.id,
          observer.id,
          %{role: :observer},
          authorize?: false
        )

      # Observer trying to send a message should fail
      result =
        Chat.send_user_message(
          %{text: "I should not be able to send this", conversation_id: conversation.id},
          actor: observer
        )

      assert {:error, _} = result
    end
  end
end
