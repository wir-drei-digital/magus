defmodule Magus.Agents.GracefulShutdownTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Agents.GracefulShutdown

  describe "checkpoint_active_agents/0" do
    test "returns :ok when no instance managers are running" do
      # In test env, InstanceManagers are disabled
      assert GracefulShutdown.checkpoint_active_agents() == :ok
    end
  end

  describe "checkpoint/2 integration" do
    test "ConversationAgent.checkpoint produces valid checkpoint data" do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      {:ok, agent} =
        Magus.Agents.ConversationAgent.new(id: "conv:#{conversation.id}")
        |> Magus.Agents.ConversationAgent.set(%{
          conversation_id: to_string(conversation.id),
          user_id: to_string(user.id),
          model_keys: %{chat: "test:model"},
          mode: :chat
        })

      {:ok, checkpoint} = Magus.Agents.ConversationAgent.checkpoint(agent, %{})

      assert checkpoint.state.conversation_id == to_string(conversation.id)
      assert checkpoint.state.user_id == to_string(user.id)
    end
  end
end
