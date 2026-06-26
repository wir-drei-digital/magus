defmodule Magus.Agents.Plugins.ToolEventPluginTest do
  use Magus.DataCase, async: true

  alias Magus.Agents.Plugins.ToolEventPlugin
  alias Magus.Agents.Plugins.Support.Helpers

  @conversation_id "tool-event-conv-id-123"
  @user_id "tool-event-user-id-456"
  @message_id "tool-event-msg-id-789"

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp build_agent(overrides \\ %{}) do
    base_state =
      Map.merge(
        %{
          conversation_id: @conversation_id,
          user_id: @user_id,
          mode: :chat,
          model_keys: %{chat: "test-model"},
          __strategy__: %{active_request_id: @message_id}
        },
        overrides
      )

    %{id: "conv:#{@conversation_id}", state: base_state}
  end

  defp build_context(agent) do
    %{agent: agent}
  end

  defp subscribe_to_conversation do
    MagusWeb.Endpoint.subscribe("agents:#{@conversation_id}")
  end

  defp make_signal(type, data) do
    Jido.Signal.new!(type, data)
  end

  # ============================================================================
  # Plugin Metadata
  # ============================================================================

  describe "plugin_spec metadata" do
    test "has correct name and state_key" do
      assert ToolEventPlugin.name() == "tool_events"
      assert ToolEventPlugin.state_key() == :tool_events
    end

    test "has signal patterns for tool lifecycle events only" do
      patterns = ToolEventPlugin.signal_patterns()
      assert "ai.tool.started" in patterns
      assert "ai.tool.result" in patterns
      assert "ai.tool.step.started" in patterns
      assert "ai.tool.step.progress" in patterns
      assert "ai.tool.step.complete" in patterns
      assert length(patterns) == 5
    end

    test "has no actions" do
      assert ToolEventPlugin.actions() == []
    end
  end

  # ============================================================================
  # Mount
  # ============================================================================

  describe "mount/2" do
    test "initializes plugin state with config" do
      agent = build_agent()
      {:ok, state} = ToolEventPlugin.mount(agent, %{some: :config})

      assert Map.has_key?(state, :config)
      assert state[:config] == %{some: :config}
    end
  end

  # ============================================================================
  # ai.tool.started → tool.start broadcast + override Noop
  # ============================================================================

  describe "handle_signal/2 with ai.tool.started" do
    test "broadcasts tool.start and returns override Noop" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.tool.started", %{
          call_id: "tool-call-3",
          tool_name: "web_fetch",
          arguments: %{"urls" => ["https://example.com"]}
        })

      result = ToolEventPlugin.handle_signal(signal, context)
      assert {:ok, {:override, Jido.Actions.Control.Noop}} = result

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{
          type: "tool.start",
          event_id: event_id,
          tool_name: "web_fetch"
        }
      }

      assert event_id == Helpers.tool_event_id_for_call_id("tool-call-3")

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "state.change", state: :running_tools}
      }
    end

    test "computes deterministic event_id from call_id" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)

      call_id = "call_#{@message_id}_1_llm-abc"

      signal =
        make_signal("ai.tool.started", %{
          call_id: call_id,
          tool_name: "web_search",
          arguments: %{}
        })

      ToolEventPlugin.handle_signal(signal, context)

      expected_event_id = Helpers.tool_event_id_for_call_id(call_id)

      assert_receive %Phoenix.Socket.Broadcast{
        payload: %{type: "tool.start", event_id: ^expected_event_id}
      }
    end

    test "resolves display name for known tools" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.tool.started", %{
          call_id: "tool-call-display",
          tool_name: "web_search",
          arguments: %{}
        })

      ToolEventPlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        payload: %{type: "tool.start", display_name: display_name}
      }

      # web_search maps to WebSearch module which has display_name/0
      assert is_binary(display_name)
      assert display_name != ""
    end

    test "falls back to tool_name string for unknown tools" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.tool.started", %{
          call_id: "tool-call-unknown",
          tool_name: "totally_unknown_tool",
          arguments: %{}
        })

      ToolEventPlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        payload: %{type: "tool.start", display_name: "totally_unknown_tool"}
      }
    end

    test "handles missing call_id gracefully" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.tool.started", %{
          tool_name: "web_fetch",
          arguments: %{}
        })

      result = ToolEventPlugin.handle_signal(signal, context)
      assert {:ok, {:override, Jido.Actions.Control.Noop}} = result

      assert_receive %Phoenix.Socket.Broadcast{
        payload: %{type: "tool.start", event_id: event_id}
      }

      # With no call_id, should still produce some UUID event_id
      assert is_binary(event_id)
      assert byte_size(event_id) > 0
    end

    test "handles string-keyed signal data" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.tool.started", %{
          "call_id" => "tool-call-str",
          "tool_name" => "roll_dice",
          "arguments" => %{"sides" => 6}
        })

      result = ToolEventPlugin.handle_signal(signal, context)
      assert {:ok, {:override, Jido.Actions.Control.Noop}} = result

      assert_receive %Phoenix.Socket.Broadcast{
        payload: %{type: "tool.start", tool_name: "roll_dice"}
      }
    end
  end

  # ============================================================================
  # ai.tool.result → tool.complete broadcast + persistence
  # ============================================================================

  describe "handle_signal/2 with ai.tool.result" do
    test "broadcasts tool.complete for successful tool execution" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.tool.result", %{
          call_id: "tool-call-1",
          tool_name: "web_search",
          result: {:ok, %{results: ["result1", "result2"]}}
        })

      result = ToolEventPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{
          type: "tool.complete",
          event_id: event_id,
          tool_name: "web_search",
          status: :success
        }
      }

      assert event_id == Helpers.tool_event_id_for_call_id("tool-call-1")

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "state.change", state: :thinking}
      }
    end

    test "broadcasts tool.complete with error status for failed tool execution" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.tool.result", %{
          call_id: "tool-call-2",
          tool_name: "web_fetch",
          result: {:error, :timeout}
        })

      result = ToolEventPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{
          type: "tool.complete",
          event_id: event_id,
          tool_name: "web_fetch",
          status: :error,
          error: ":timeout"
        }
      }

      assert event_id == Helpers.tool_event_id_for_call_id("tool-call-2")

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "state.change", state: :thinking}
      }
    end

    test "handles string-keyed signal data" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.tool.result", %{
          "call_id" => "tool-call-str-result",
          "tool_name" => "roll_dice",
          "result" => {:ok, %{value: 4}}
        })

      result = ToolEventPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      assert_receive %Phoenix.Socket.Broadcast{
        payload: %{type: "tool.complete", tool_name: "roll_dice", status: :success}
      }
    end
  end

  # ============================================================================
  # Passthrough for unrelated signals
  # ============================================================================

  describe "handle_signal/2 with unrelated signals" do
    test "passes through unrecognized signal types" do
      agent = build_agent()
      context = build_context(agent)

      signal = make_signal("ai.llm.delta", %{delta: "hello"})

      result = ToolEventPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result
    end

    test "passes through message.user signals" do
      agent = build_agent()
      context = build_context(agent)

      signal = make_signal("message.user", %{text: "Hello"})

      result = ToolEventPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result
    end

    test "passes through ai.request.completed signals" do
      agent = build_agent()
      context = build_context(agent)

      signal = make_signal("ai.request.completed", %{request_id: "req-1"})

      result = ToolEventPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result
    end
  end

  # ============================================================================
  # Conversation ID extraction
  # ============================================================================

  describe "conversation_id extraction" do
    test "extracts conversation_id from agent state" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)
      expected_topic = "agents:#{@conversation_id}"

      signal =
        make_signal("ai.tool.started", %{
          call_id: "tool-call-conv",
          tool_name: "web_search",
          arguments: %{}
        })

      ToolEventPlugin.handle_signal(signal, context)

      # Verify broadcast went to the correct topic
      assert_receive %Phoenix.Socket.Broadcast{
        topic: ^expected_topic,
        payload: %{type: "state.change"}
      }
    end

    test "extracts conversation_id from agent ID when not in state" do
      conv_id = "fallback-conv-id"
      expected_topic = "agents:#{conv_id}"
      MagusWeb.Endpoint.subscribe(expected_topic)

      agent = %{id: "conv:#{conv_id}", state: %{}}
      context = build_context(agent)

      signal =
        make_signal("ai.tool.started", %{
          call_id: "tool-call-fallback",
          tool_name: "web_search",
          arguments: %{}
        })

      ToolEventPlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: ^expected_topic,
        payload: %{type: "state.change"}
      }
    end
  end
end
