defmodule Magus.Agents.RecoveryTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.Recovery

  setup do
    user = generate(user())
    conversation = generate(conversation(actor: user))

    %{user: user, conversation: conversation}
  end

  # Registers a dummy live process under the `:conversations` InstanceManager
  # Registry so `await_agent_ready/1` succeeds (`lookup` finds a live pid)
  # without needing to boot a full ConversationAgent/ReactStrategy stack.
  # The registry itself may already be running (started by another test in
  # the same VM); we only need the registration entry, not the whole
  # InstanceManager supervision tree.
  defp register_fake_agent(conversation_id) do
    registry_name = Jido.Agent.InstanceManager.registry_name(:conversations)

    case Process.whereis(registry_name) do
      nil -> start_supervised!({Registry, keys: :unique, name: registry_name})
      _pid -> :ok
    end

    agent_id = "conv:#{conversation_id}"
    test_pid = self()

    fake_agent_pid =
      spawn(fn ->
        {:ok, _} = Registry.register(registry_name, agent_id, nil)
        send(test_pid, :registered)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :registered
    fake_agent_pid
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

  describe "recover_interrupted_turn/2" do
    test "aborts when agent never becomes ready, still runs cleanup", %{
      user: user,
      conversation: conversation
    } do
      # Create a message and force it into :streaming to simulate an
      # interrupted turn that needs sweeping.
      message = generate(message(actor: user, conversation_id: conversation.id, text: "Hello"))

      {:ok, streaming_message} =
        message
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(:status, :streaming)
        |> Ash.Changeset.force_change_attribute(:complete, false)
        |> Ash.update(authorize?: false)

      conversation_id = to_string(conversation.id)

      MagusWeb.Endpoint.subscribe("agents:#{conversation_id}")

      # No agent process is registered for this conversation in the test
      # environment, so await_agent_ready/1 exhausts its retries and the
      # new behavior must abort rather than proceed with re-dispatch.
      result = Recovery.recover_interrupted_turn(conversation_id, streaming_message.id)

      assert result == :aborted_not_ready

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "state.change", state: :idle}
      }

      {:ok, reloaded} = Ash.get(Magus.Chat.Message, streaming_message.id, authorize?: false)
      assert reloaded.status == :error
      assert reloaded.complete == true
    end

    test "skips re-dispatch when a newer user message exists", %{
      user: user,
      conversation: conversation
    } do
      conversation_id = to_string(conversation.id)

      # M1: the interrupted message that recovery would normally re-dispatch.
      m1 = generate(message(actor: user, conversation_id: conversation.id, text: "First"))

      # Ensure strict ordering even if inserted_at has coarse resolution.
      Process.sleep(10)

      # M2: a newer user message that arrived while the agent was
      # hibernated/recovering. It supersedes M1 and will drive its own turn,
      # so M1 must NOT be re-dispatched.
      _m2 = generate(message(actor: user, conversation_id: conversation.id, text: "Second"))

      # Register a live dummy process so await_agent_ready/1 succeeds and
      # recovery reaches the re-dispatch decision instead of aborting.
      register_fake_agent(conversation_id)

      result = Recovery.recover_interrupted_turn(conversation_id, m1.id)

      assert result == :skipped_newer
    end

    test "re-dispatches when the interrupted message is still the newest", %{
      user: user,
      conversation: conversation
    } do
      conversation_id = to_string(conversation.id)

      m1 = generate(message(actor: user, conversation_id: conversation.id, text: "Only message"))

      register_fake_agent(conversation_id)

      result = Recovery.recover_interrupted_turn(conversation_id, m1.id)

      assert result == {:dispatched, m1.id}
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
