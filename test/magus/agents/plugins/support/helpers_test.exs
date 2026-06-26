defmodule Magus.Agents.Plugins.Support.HelpersTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Plugins.Support.Helpers
  alias Magus.Chat

  # magus-k3at: in a shared (multiplayer/workspace) conversation, usage/billing
  # must be attributed to the member who sent the triggering message, not the
  # conversation owner the agent was started for.
  describe "acting_user_id/2" do
    setup do
      owner = generate(user())
      sender = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)

      # A message sent by a non-owner member of the conversation.
      {:ok, message} =
        Chat.create_message(
          %{text: "from a member", conversation_id: conversation.id},
          actor: sender,
          authorize?: false
        )

      agent = %{state: %{user_id: owner.id}}
      %{owner: owner, sender: sender, message: message, agent: agent}
    end

    test "attributes the turn to the message sender, not the conversation owner",
         %{agent: agent, owner: owner, sender: sender, message: message} do
      # Precondition: the message records its sender, and the agent's stored
      # user is the (different) owner.
      assert message.created_by_id == sender.id
      assert agent.state.user_id == owner.id
      refute sender.id == owner.id

      assert Helpers.acting_user_id(agent, message.id) == sender.id
    end

    test "falls back to the owner for an autonomous turn (no triggering message)",
         %{agent: agent, owner: owner} do
      assert Helpers.acting_user_id(agent, nil) == owner.id
    end

    test "falls back to the owner for an unknown message id",
         %{agent: agent, owner: owner} do
      assert Helpers.acting_user_id(agent, Ash.UUID.generate()) == owner.id
    end
  end
end
