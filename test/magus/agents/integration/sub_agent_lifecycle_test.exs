defmodule Magus.Agents.Integration.SubAgentLifecycleTest do
  @moduledoc """
  End-to-end integration test for the unified sub-agent lifecycle card.

  Validates the full signal flow:
  1. spawn_sub_agent sets source_event_id on AgentRun
  2. RunOrchestrator run.started includes source_event_id
  3. Child tool events relay as tool.step.start/complete to parent
  4. AgentRunCompletionPlugin sends relay (not run.completed) when source_event_id set
  5. RunOrchestrator enqueue run.progress includes source_event_id
  """

  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.Plugins.{ToolEventPlugin, AgentRunCompletionPlugin}
  alias Magus.Agents.Plugins.Support.Helpers
  alias Magus.Agents.RunOrchestrator
  alias Magus.Agents.Tools.Tasks.SpawnSubAgent

  @moduletag :integration

  setup do
    user = generate(user())
    parent = generate(conversation(actor: user))
    user = Ash.load!(user, [], authorize?: false)

    context = %{
      conversation_id: parent.id,
      user_id: user.id,
      user: user
    }

    # Subscribe to parent's PubSub topic
    parent_topic = "agents:#{parent.id}"
    MagusWeb.Endpoint.subscribe(parent_topic)

    %{user: user, parent: parent, context: context, parent_topic: parent_topic}
  end

  describe "source_event_id propagation" do
    test "spawn_sub_agent stores source_event_id derived from __event_id__", %{
      context: context
    } do
      # Simulate ReAct worker enrichment: __event_id__ is the LLM's tool call ID
      call_id = "call_test_sub_agent_#{System.unique_integer([:positive])}"
      context_with_event = Map.put(context, :__event_id__, call_id)

      {:ok, result} =
        SpawnSubAgent.run(
          %{"objective" => "Test lifecycle", "system_prompt" => "Be quick."},
          context_with_event
        )

      assert result.status == "spawning"

      # Verify AgentRun has source_event_id set
      {:ok, run} = Magus.Agents.get_agent_run(result.task_id, authorize?: false)
      assert run.source_event_id != nil

      # source_event_id should be the deterministic UUID derived from call_id
      expected_event_id = Helpers.tool_event_id_for_call_id(call_id)
      assert run.source_event_id == expected_event_id
    end

    test "spawn_sub_agent without __event_id__ stores nil source_event_id", %{
      context: context
    } do
      # No __event_id__ in context (legacy behavior)
      {:ok, result} =
        SpawnSubAgent.run(
          %{"objective" => "Legacy spawn", "system_prompt" => "Be quick."},
          context
        )

      assert result.status == "spawning"

      {:ok, run} = Magus.Agents.get_agent_run(result.task_id, authorize?: false)
      assert run.source_event_id == nil
    end
  end

  describe "run lifecycle signal suppression" do
    test "run.started includes source_event_id from run_payload", %{parent: parent} do
      user = generate(user())
      user = Ash.load!(user, [], authorize?: false)
      child = generate(conversation(actor: user))

      source_event_id = Ash.UUIDv7.generate()

      # Directly enqueue with source_event_id
      {:ok, run} =
        RunOrchestrator.enqueue(%{
          kind: :subtask,
          source_conversation_id: parent.id,
          source_event_id: source_event_id,
          target_conversation_id: child.id,
          initiator_user_id: user.id,
          request_id: "subtask:#{Ash.UUIDv7.generate()}",
          model_key: "test:model",
          objective: "Test run lifecycle"
        })

      # Verify the run has source_event_id persisted
      {:ok, reloaded} = Magus.Agents.get_agent_run(run.id, authorize?: false)
      assert reloaded.source_event_id == source_event_id
    end

    test "enqueue run.progress includes source_event_id", %{
      parent: parent,
      parent_topic: parent_topic
    } do
      user = generate(user())
      user = Ash.load!(user, [], authorize?: false)
      child = generate(conversation(actor: user))

      source_event_id = Ash.UUIDv7.generate()

      {:ok, _run} =
        RunOrchestrator.enqueue(%{
          kind: :subtask,
          source_conversation_id: parent.id,
          source_event_id: source_event_id,
          target_conversation_id: child.id,
          initiator_user_id: user.id,
          request_id: "subtask:#{Ash.UUIDv7.generate()}",
          model_key: "test:model",
          objective: "Test enqueue progress"
        })

      # The enqueue sends a run.progress signal - check if source_event_id is included
      assert_receive %Phoenix.Socket.Broadcast{
        topic: ^parent_topic,
        event: "agent_signal",
        payload: payload
      }

      assert payload.type == "run.progress"
      # This is the key assertion: source_event_id must be in the payload
      # so the frontend can suppress run cards for unified lifecycle
      assert payload[:source_event_id] == source_event_id,
             "run.progress from enqueue must include source_event_id, got: #{inspect(Map.keys(payload))}"
    end
  end

  describe "child tool relay to parent" do
    setup %{parent: parent} do
      user = generate(user())
      user = Ash.load!(user, [], authorize?: false)
      child = generate(conversation(actor: user))

      source_event_id = Ash.UUIDv7.generate()

      {:ok, run} =
        RunOrchestrator.enqueue(%{
          kind: :subtask,
          source_conversation_id: parent.id,
          source_event_id: source_event_id,
          target_conversation_id: child.id,
          initiator_user_id: user.id,
          request_id: "subtask:#{Ash.UUIDv7.generate()}",
          model_key: "test:model",
          objective: "Test child relay"
        })

      {:ok, run} = Magus.Agents.start_agent_run(run, authorize?: false)

      %{child: child, run: run, source_event_id: source_event_id}
    end

    test "child tool.start relays as tool.step.start to parent", %{
      child: child,
      source_event_id: source_event_id,
      parent_topic: parent_topic
    } do
      # Drain any signals from setup (enqueue sends run.progress, start sends run.started)
      drain_signals()

      signal = %Jido.Signal{
        id: Ash.UUIDv7.generate(),
        type: "ai.tool.started",
        source: "test",
        data: %{
          tool_name: "web_search",
          call_id: "call_child_tool_1",
          arguments: %{"query" => "elixir patterns"}
        }
      }

      agent = %{state: %{conversation_id: to_string(child.id)}}
      ToolEventPlugin.handle_signal(signal, %{agent: agent})

      # Should receive tool.step.start on parent topic with source_event_id as event_id
      assert_receive %Phoenix.Socket.Broadcast{
        topic: ^parent_topic,
        event: "agent_signal",
        payload: %{
          type: "tool.step.start",
          event_id: ^source_event_id,
          label: label
        }
      }

      assert is_binary(label)
    end

    test "child tool.complete relays as tool.step.complete to parent", %{
      child: child,
      source_event_id: source_event_id,
      parent_topic: parent_topic
    } do
      drain_signals()

      signal = %Jido.Signal{
        id: Ash.UUIDv7.generate(),
        type: "ai.tool.result",
        source: "test",
        data: %{
          tool_name: "web_search",
          call_id: "call_child_tool_2",
          result: {:ok, %{results: ["found something"]}}
        }
      }

      agent = %{state: %{conversation_id: to_string(child.id)}}
      ToolEventPlugin.handle_signal(signal, %{agent: agent})

      assert_receive %Phoenix.Socket.Broadcast{
        topic: ^parent_topic,
        event: "agent_signal",
        payload: %{
          type: "tool.step.complete",
          event_id: ^source_event_id,
          status: :complete
        }
      }
    end
  end

  describe "completion relay (AgentRunCompletionPlugin)" do
    test "sends relay_tool_step_complete instead of run.completed when source_event_id set", %{
      parent: parent,
      parent_topic: _parent_topic
    } do
      user = generate(user())
      user = Ash.load!(user, [], authorize?: false)
      child = generate(conversation(actor: user))

      source_event_id = Ash.UUIDv7.generate()

      {:ok, run} =
        RunOrchestrator.enqueue(%{
          kind: :subtask,
          source_conversation_id: parent.id,
          source_event_id: source_event_id,
          target_conversation_id: child.id,
          initiator_user_id: user.id,
          request_id: "subtask:#{Ash.UUIDv7.generate()}",
          model_key: "test:model",
          objective: "Test completion relay"
        })

      {:ok, run} = Magus.Agents.start_agent_run(run, authorize?: false)

      drain_signals()

      # Simulate completion via the plugin
      completion_signal = %Jido.Signal{
        id: Ash.UUIDv7.generate(),
        type: "ai.request.completed",
        source: "test",
        data: %{request_id: run.request_id}
      }

      # Mock agent state for the plugin
      agent = %{
        state: %{
          conversation_id: to_string(child.id),
          strategy_state: %{streaming_text: "Research completed successfully."}
        }
      }

      AgentRunCompletionPlugin.handle_signal(completion_signal, %{agent: agent})

      # Collect all signals received
      signals = collect_signals(500)

      # Should receive tool.step.complete (relay) NOT run.completed
      step_complete =
        Enum.find(signals, fn s -> s.payload.type == "tool.step.complete" end)

      run_completed =
        Enum.find(signals, fn s -> s.payload.type == "run.completed" end)

      assert step_complete != nil,
             "Expected tool.step.complete signal on parent topic, got types: #{inspect(Enum.map(signals, & &1.payload.type))}"

      assert step_complete.payload.event_id == source_event_id
      assert step_complete.payload.status == :complete

      assert run_completed == nil,
             "run.completed should NOT be sent when source_event_id is set"
    end

    test "sends run.completed (legacy) when source_event_id is nil", %{
      parent: parent,
      parent_topic: _parent_topic
    } do
      user = generate(user())
      user = Ash.load!(user, [], authorize?: false)
      child = generate(conversation(actor: user))

      {:ok, run} =
        RunOrchestrator.enqueue(%{
          kind: :subtask,
          source_conversation_id: parent.id,
          source_event_id: nil,
          target_conversation_id: child.id,
          initiator_user_id: user.id,
          request_id: "subtask:#{Ash.UUIDv7.generate()}",
          model_key: "test:model",
          objective: "Test legacy completion"
        })

      {:ok, run} = Magus.Agents.start_agent_run(run, authorize?: false)

      drain_signals()

      completion_signal = %Jido.Signal{
        id: Ash.UUIDv7.generate(),
        type: "ai.request.completed",
        source: "test",
        data: %{request_id: run.request_id}
      }

      agent = %{
        state: %{
          conversation_id: to_string(child.id),
          strategy_state: %{streaming_text: "Done."}
        }
      }

      AgentRunCompletionPlugin.handle_signal(completion_signal, %{agent: agent})

      signals = collect_signals(500)

      run_completed =
        Enum.find(signals, fn s -> s.payload.type == "run.completed" end)

      step_complete =
        Enum.find(signals, fn s -> s.payload.type == "tool.step.complete" end)

      assert run_completed != nil,
             "Expected run.completed for legacy (nil source_event_id), got types: #{inspect(Enum.map(signals, & &1.payload.type))}"

      assert step_complete == nil
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp drain_signals(timeout \\ 100) do
    receive do
      %Phoenix.Socket.Broadcast{} -> drain_signals(timeout)
    after
      timeout -> :ok
    end
  end

  defp collect_signals(timeout) do
    collect_signals_acc([], timeout)
  end

  defp collect_signals_acc(acc, timeout) do
    receive do
      %Phoenix.Socket.Broadcast{} = broadcast ->
        collect_signals_acc([broadcast | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end
end
