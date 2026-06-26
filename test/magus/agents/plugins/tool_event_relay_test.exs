defmodule Magus.Agents.Plugins.ToolEventRelayTest do
  @moduledoc """
  Tests that ToolEventPlugin relays child tool events as steps to the parent conversation.
  """
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.Plugins.ToolEventPlugin
  alias Magus.Agents.RunOrchestrator

  @moduletag :integration

  setup do
    user = generate(user())
    parent = generate(conversation(actor: user))
    child = generate(conversation(actor: user))
    user = Ash.load!(user, [], authorize?: false)

    source_event_id = Ash.UUIDv7.generate()

    # Create an AgentRun linking parent -> child with source_event_id
    {:ok, run} =
      RunOrchestrator.enqueue(%{
        kind: :subtask,
        source_conversation_id: parent.id,
        source_event_id: source_event_id,
        target_conversation_id: child.id,
        initiator_user_id: user.id,
        request_id: "subtask:#{Ash.UUIDv7.generate()}",
        model_key: "test:model",
        objective: "Test relay"
      })

    {:ok, run} = Magus.Agents.start_agent_run(run, authorize?: false)

    # Subscribe to parent's PubSub topic
    parent_topic = "agents:#{parent.id}"
    MagusWeb.Endpoint.subscribe(parent_topic)

    %{
      parent: parent,
      child: child,
      run: run,
      source_event_id: source_event_id,
      parent_topic: parent_topic
    }
  end

  test "relays child tool.start as tool.step.start to parent", %{
    child: child,
    source_event_id: source_event_id,
    parent_topic: parent_topic
  } do
    signal = %Jido.Signal{
      id: Ash.UUIDv7.generate(),
      type: "ai.tool.started",
      source: "test",
      data: %{
        tool_name: "web_search",
        call_id: "call_test_123",
        arguments: %{"query" => "elixir patterns"}
      }
    }

    child_conversation_id = to_string(child.id)
    agent = %{state: %{conversation_id: child_conversation_id}}
    context = %{agent: agent}

    ToolEventPlugin.handle_signal(signal, context)

    # Should receive tool.step.start on parent topic
    assert_receive %Phoenix.Socket.Broadcast{
      topic: ^parent_topic,
      event: "agent_signal",
      payload: %{
        type: "tool.step.start",
        event_id: ^source_event_id,
        label: label
      }
    }

    assert is_binary(label) and label != ""
  end

  test "relays child tool.complete as tool.step.complete to parent", %{
    child: child,
    source_event_id: source_event_id,
    parent_topic: parent_topic
  } do
    signal = %Jido.Signal{
      id: Ash.UUIDv7.generate(),
      type: "ai.tool.result",
      source: "test",
      data: %{
        tool_name: "web_search",
        call_id: "call_test_456",
        result: {:ok, %{results: ["result1"]}}
      }
    }

    child_conversation_id = to_string(child.id)
    agent = %{state: %{conversation_id: child_conversation_id}}
    context = %{agent: agent}

    ToolEventPlugin.handle_signal(signal, context)

    # Should receive tool.step.complete on parent topic
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

  test "does not relay when no active run exists", %{child: child, run: run} do
    # Complete the run so no active run exists
    {:ok, _} =
      Magus.Agents.complete_agent_run(run, %{result_text: "Done"}, authorize?: false)

    signal = %Jido.Signal{
      id: Ash.UUIDv7.generate(),
      type: "ai.tool.started",
      source: "test",
      data: %{
        tool_name: "web_search",
        call_id: "call_test_789",
        arguments: %{}
      }
    }

    child_conversation_id = to_string(child.id)
    agent = %{state: %{conversation_id: child_conversation_id}}
    context = %{agent: agent}

    ToolEventPlugin.handle_signal(signal, context)

    # Should NOT receive tool.step.start (no active run)
    refute_receive %Phoenix.Socket.Broadcast{
                     payload: %{type: "tool.step.start"}
                   },
                   100
  end
end
