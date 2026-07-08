defmodule Magus.Agents.RecoveryTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  require Ash.Query

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
        forward_casts(test_pid)
      end)

    assert_receive :registered
    fake_agent_pid
  end

  # Forwards GenServer casts (the dispatched signals) to the test process so
  # tests can assert on what Recovery/Dispatcher actually sent the agent.
  defp forward_casts(test_pid) do
    receive do
      :stop ->
        :ok

      {:"$gen_cast", payload} ->
        send(test_pid, {:agent_cast, payload})
        forward_casts(test_pid)

      _other ->
        forward_casts(test_pid)
    end
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

  describe "sweep_streaming_messages/1 interruption event" do
    test "creates a visible event message when it sweeps stuck rows", %{
      user: user,
      conversation: conversation
    } do
      message = generate(message(actor: user, conversation_id: conversation.id, text: "Hi"))

      {:ok, _streaming} =
        message
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(:status, :streaming)
        |> Ash.Changeset.force_change_attribute(:complete, false)
        |> Ash.update(authorize?: false)

      :ok = Recovery.sweep_streaming_messages(to_string(conversation.id))

      events =
        Magus.Chat.Message
        |> Ash.Query.filter(conversation_id == ^conversation.id and message_type == :event)
        |> Ash.read!(authorize?: false)

      assert [event] = events
      assert event.metadata["event_kind"] == "turn_interrupted"
      assert event.text =~ "interrupted"
    end

    test "creates no event when there is nothing to sweep", %{conversation: conversation} do
      :ok = Recovery.sweep_streaming_messages(to_string(conversation.id))

      events =
        Magus.Chat.Message
        |> Ash.Query.filter(conversation_id == ^conversation.id and message_type == :event)
        |> Ash.read!(authorize?: false)

      assert events == []
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

    test "the re-dispatched signal is marked as a recovery retry", %{
      user: user,
      conversation: conversation
    } do
      conversation_id = to_string(conversation.id)

      m1 = generate(message(actor: user, conversation_id: conversation.id, text: "Only message"))

      register_fake_agent(conversation_id)

      assert {:dispatched, _} = Recovery.recover_interrupted_turn(conversation_id, m1.id)

      assert_receive {:agent_cast, {:signal, signal}}, 2_000
      assert signal.type == "message.user"
      assert signal.data[:recovery_retry] == true
    end
  end

  describe "activity trace" do
    test "recovery on a conversation with custom_agent_id writes exactly one :recovery activity row",
         %{user: user} do
      agent = custom_agent(user, %{heartbeat_enabled: true, is_paused: false})
      conversation = generate(conversation(actor: user, custom_agent_id: agent.id))
      conversation_id = to_string(conversation.id)

      m1 = generate(message(actor: user, conversation_id: conversation.id, text: "Only message"))

      register_fake_agent(conversation_id)

      result = Recovery.recover_interrupted_turn(conversation_id, m1.id)
      assert result == {:dispatched, m1.id}

      {:ok, logs} = Magus.Agents.list_agent_activity(agent.id, authorize?: false)

      recovery_logs = Enum.filter(logs, &(&1.activity_type == :recovery))
      assert length(recovery_logs) == 1
    end

    test "recovery on a plain user conversation (no custom_agent_id) writes zero activity rows",
         %{user: user, conversation: conversation} do
      conversation_id = to_string(conversation.id)
      assert conversation.custom_agent_id == nil

      m1 = generate(message(actor: user, conversation_id: conversation.id, text: "Only message"))

      register_fake_agent(conversation_id)

      result = Recovery.recover_interrupted_turn(conversation_id, m1.id)
      assert result == {:dispatched, m1.id}

      logs =
        Magus.Agents.AgentActivityLog
        |> Ash.Query.filter(details["conversation_id"] == ^conversation_id)
        |> Ash.read!(authorize?: false)

      assert logs == []
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
