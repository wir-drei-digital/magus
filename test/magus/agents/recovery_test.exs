defmodule Magus.Agents.RecoveryTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.Recovery

  setup do
    user = generate(user())
    conversation = generate(conversation(actor: user))

    %{user: user, conversation: conversation}
  end

  describe "maybe_recover/1" do
    test "no-ops when no __recovery__ in state", %{conversation: conversation} do
      agent = %{
        id: "conv:#{conversation.id}",
        state: %{conversation_id: to_string(conversation.id)}
      }

      result = Recovery.maybe_recover(agent)

      assert result == agent
    end

    test "no-ops when __recovery__ has was_active: false", %{conversation: conversation} do
      agent = %{
        id: "conv:#{conversation.id}",
        state: %{
          conversation_id: to_string(conversation.id),
          __recovery__: %{was_active: false}
        }
      }

      result = Recovery.maybe_recover(agent)

      assert result == agent
    end

    test "clears __recovery__ from state when triggered", %{conversation: conversation} do
      conversation_id = to_string(conversation.id)

      agent = %{
        id: "conv:#{conversation.id}",
        state: %{
          conversation_id: conversation_id,
          user_id: "some-user-id",
          __recovery__: %{was_active: true, active_message_id: nil}
        }
      }

      result = Recovery.maybe_recover(agent)

      # __recovery__ should be cleared
      refute Map.has_key?(result.state, :__recovery__)
      # Other state should be preserved
      assert result.state[:conversation_id] == conversation_id
      assert result.state[:user_id] == "some-user-id"
    end

    test "broadcasts state_change :running when triggered", %{conversation: conversation} do
      conversation_id = to_string(conversation.id)

      # Subscribe to PubSub before triggering recovery
      MagusWeb.Endpoint.subscribe("agents:#{conversation_id}")

      agent = %{
        id: "conv:#{conversation.id}",
        state: %{
          conversation_id: conversation_id,
          __recovery__: %{was_active: true, active_message_id: nil}
        }
      }

      Recovery.maybe_recover(agent)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "state.change", state: :running}
      }
    end
  end

  describe "cleanup_interrupted_messages" do
    test "marks streaming messages as error", %{user: user, conversation: conversation} do
      # Create a message via the generator
      message = generate(message(actor: user, conversation_id: conversation.id, text: "Hello"))
      assert message.status == :complete

      # Force the message status to :streaming to simulate an interrupted turn
      {:ok, streaming_message} =
        message
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(:status, :streaming)
        |> Ash.Changeset.force_change_attribute(:complete, false)
        |> Ash.update(authorize?: false)

      assert streaming_message.status == :streaming

      conversation_id = to_string(conversation.id)

      # Subscribe to PubSub so recovery can broadcast
      MagusWeb.Endpoint.subscribe("agents:#{conversation_id}")

      # Trigger recovery with __recovery__ set
      agent = %{
        id: "conv:#{conversation.id}",
        state: %{
          conversation_id: conversation_id,
          __recovery__: %{was_active: true, active_message_id: nil}
        }
      }

      Recovery.maybe_recover(agent)

      # Wait for the async task to complete cleanup
      Process.sleep(1000)

      # Reload the message and verify it was marked as error
      {:ok, reloaded} = Ash.get(Magus.Chat.Message, streaming_message.id, authorize?: false)
      assert reloaded.status == :error
      assert reloaded.complete == true
    end
  end
end
