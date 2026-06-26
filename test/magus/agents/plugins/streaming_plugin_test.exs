defmodule Magus.Agents.Plugins.StreamingPluginTest do
  use Magus.DataCase, async: true

  alias Magus.Agents.Plugins.StreamingPlugin
  alias Magus.Agents.Plugins.Support.Helpers

  @conversation_id "streaming-plugin-conv-id"
  @user_id "test-user-id-456"
  @message_id "test-msg-id-789"

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

  defp expected_response_id do
    Helpers.response_id_for_request(@message_id)
  end

  defp expected_turn_response_id(iteration) do
    Helpers.response_id_for_turn(@message_id, iteration)
  end

  # ============================================================================
  # Plugin Metadata
  # ============================================================================

  describe "plugin metadata" do
    test "has correct name and state_key" do
      assert StreamingPlugin.name() == "streaming"
      assert StreamingPlugin.state_key() == :streaming
    end

    test "has signal patterns covering streaming signal types" do
      patterns = StreamingPlugin.signal_patterns()
      assert "ai.llm.delta" in patterns
      assert "ai.llm.turn.started" in patterns
      assert "ai.llm.turn.completed" in patterns
      assert "ai.request.started" in patterns
    end

    test "does not include non-streaming signal patterns" do
      patterns = StreamingPlugin.signal_patterns()
      refute "ai.llm.response" in patterns
      refute "ai.tool.started" in patterns
      refute "ai.tool.result" in patterns
      refute "message.user" in patterns
      refute "message.cancel" in patterns
    end
  end

  # ============================================================================
  # Mount
  # ============================================================================

  describe "mount/2" do
    test "initializes state with config" do
      agent = build_agent()
      {:ok, state} = StreamingPlugin.mount(agent, %{some: :config})

      assert Map.has_key?(state, :config)
      assert state[:config] == %{some: :config}
    end
  end

  # ============================================================================
  # Content Delta Broadcasting (ai.llm.delta → text.chunk)
  # ============================================================================

  describe "handle_signal/2 with ai.llm.delta (content)" do
    test "broadcasts text.chunk for content delta" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)
      expected_id = expected_response_id()

      signal =
        make_signal("ai.llm.delta", %{
          call_id: "call-1",
          delta: "Hello",
          chunk_type: :content
        })

      result = StreamingPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "text.chunk", delta: "Hello", message_id: ^expected_id}
      }
    end

    test "accumulates text from strategy state" do
      subscribe_to_conversation()

      agent =
        build_agent(%{
          __strategy__: %{
            active_request_id: @message_id,
            streaming_text: "Hello world"
          }
        })

      context = build_context(agent)

      signal =
        make_signal("ai.llm.delta", %{
          call_id: "call-1",
          delta: "world",
          chunk_type: :content
        })

      result = StreamingPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "text.chunk", delta: "world", text: "Hello world"}
      }
    end

    test "passes custom_agent_opts for content chunks" do
      subscribe_to_conversation()

      agent =
        build_agent(%{
          custom_agent_id: "agent-42",
          custom_agent_name: "My Custom Bot"
        })

      context = build_context(agent)

      signal =
        make_signal("ai.llm.delta", %{
          call_id: "call-1",
          delta: "Hi",
          chunk_type: :content
        })

      assert {:ok, :continue} = StreamingPlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: payload
      }

      assert payload.type == "text.chunk"
      assert payload.custom_agent_id == "agent-42"
      assert payload.custom_agent_name == "My Custom Bot"
    end

    test "derives message_id from call_id with iteration" do
      subscribe_to_conversation()
      expected_id = expected_turn_response_id(1)

      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.llm.delta", %{
          call_id: "call_#{@message_id}_1_llm-1",
          delta: "chunk",
          chunk_type: :content
        })

      assert {:ok, :continue} = StreamingPlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "text.chunk", message_id: ^expected_id}
      }
    end

    test "does not broadcast when delta is empty for content" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.llm.delta", %{
          call_id: "call-1",
          delta: "",
          chunk_type: :content
        })

      assert {:ok, :continue} = StreamingPlugin.handle_signal(signal, context)

      refute_receive %Phoenix.Socket.Broadcast{
                       payload: %{type: "text.chunk"}
                     },
                     100
    end
  end

  # ============================================================================
  # Thinking Delta Broadcasting (ai.llm.delta → thinking.chunk)
  # ============================================================================

  describe "handle_signal/2 with ai.llm.delta (thinking)" do
    test "broadcasts thinking.chunk for thinking delta" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)
      expected_id = expected_response_id()

      signal =
        make_signal("ai.llm.delta", %{
          call_id: "call-1",
          delta: "Let me think...",
          chunk_type: :thinking
        })

      result = StreamingPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "state.change", state: :reasoning}
      }

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{
          type: "thinking.chunk",
          delta: "Let me think...",
          message_id: ^expected_id
        }
      }
    end

    test "broadcasts thinking.chunk with accumulated text" do
      subscribe_to_conversation()

      agent =
        build_agent(%{
          __strategy__: %{
            active_request_id: @message_id,
            streaming_thinking: "I need to consider"
          }
        })

      context = build_context(agent)

      signal =
        make_signal("ai.llm.delta", %{
          call_id: "call-1",
          delta: " the options",
          chunk_type: :thinking
        })

      assert {:ok, :continue} = StreamingPlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{
          type: "thinking.chunk",
          text: "I need to consider",
          delta: " the options"
        }
      }
    end

    test "broadcasts thinking.chunk even when delta is empty but accumulated is present" do
      subscribe_to_conversation()

      agent =
        build_agent(%{
          __strategy__: %{
            active_request_id: @message_id,
            streaming_thinking: "Some accumulated thinking"
          }
        })

      context = build_context(agent)

      signal =
        make_signal("ai.llm.delta", %{
          call_id: "call-1",
          delta: "",
          chunk_type: :thinking
        })

      assert {:ok, :continue} = StreamingPlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "thinking.chunk", text: "Some accumulated thinking", delta: ""}
      }
    end
  end

  # ============================================================================
  # Request Started (ai.request.started → state.change)
  # ============================================================================

  describe "handle_signal/2 with ai.request.started" do
    test "broadcasts state.change(:thinking) for chat mode" do
      subscribe_to_conversation()
      agent = build_agent(%{mode: :chat})
      context = build_context(agent)

      signal =
        make_signal("ai.request.started", %{
          request_id: "req-1",
          query: "Hello"
        })

      result = StreamingPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "state.change", state: :thinking}
      }
    end

    test "broadcasts state.change(:reasoning) for reasoning mode" do
      subscribe_to_conversation()
      agent = build_agent(%{mode: :reasoning})
      context = build_context(agent)

      signal =
        make_signal("ai.request.started", %{
          request_id: "req-1",
          query: "Reason about this"
        })

      result = StreamingPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "state.change", state: :reasoning}
      }
    end

    test "broadcasts state.change(:thinking) for search mode" do
      subscribe_to_conversation()
      agent = build_agent(%{mode: :search})
      context = build_context(agent)

      signal = make_signal("ai.request.started", %{request_id: "req-1"})

      assert {:ok, :continue} = StreamingPlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "state.change", state: :thinking}
      }
    end

    test "broadcasts state.change(:thinking) when mode is nil" do
      subscribe_to_conversation()
      agent = build_agent(%{mode: nil})
      context = build_context(agent)

      signal = make_signal("ai.request.started", %{request_id: "req-1"})

      assert {:ok, :continue} = StreamingPlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "state.change", state: :thinking}
      }
    end
  end

  # ============================================================================
  # Turn Lifecycle (ai.llm.turn.started / ai.llm.turn.completed)
  # ============================================================================

  describe "handle_signal/2 with ai.llm.turn.started" do
    test "broadcasts turn.started with signal data" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.llm.turn.started", %{
          request_id: @message_id,
          turn_id: "#{@message_id}:1",
          iteration: 1,
          call_id: "call_#{@message_id}_1_llm-1",
          model: "test-model"
        })

      assert {:ok, :continue} = StreamingPlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: payload
      }

      assert payload.type == "turn.started"
      assert payload.turn_id == "#{@message_id}:1"
      assert payload.iteration == 1
      assert payload.request_id == @message_id
      assert payload.model == "test-model"
    end
  end

  describe "handle_signal/2 with ai.llm.turn.completed" do
    test "broadcasts turn.completed for final_answer turn" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.llm.turn.completed", %{
          request_id: @message_id,
          turn_id: "#{@message_id}:1",
          iteration: 1,
          turn_type: :final_answer
        })

      assert {:ok, :continue} = StreamingPlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "turn.completed", turn_type: :final_answer}
      }

      # Should NOT get running_tools state change for final_answer turns
      refute_receive %Phoenix.Socket.Broadcast{
                       payload: %{type: "state.change", state: :running_tools}
                     },
                     100
    end

    test "broadcasts turn.completed and running_tools state for tool_calls turn" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.llm.turn.completed", %{
          request_id: @message_id,
          turn_id: "#{@message_id}:1",
          iteration: 1,
          turn_type: :tool_calls
        })

      assert {:ok, :continue} = StreamingPlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "turn.completed", turn_type: :tool_calls}
      }

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "state.change", state: :running_tools}
      }
    end

    test "normalizes string turn_type to atom" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.llm.turn.completed", %{
          request_id: @message_id,
          turn_id: "#{@message_id}:1",
          iteration: 1,
          turn_type: "tool_calls"
        })

      assert {:ok, :continue} = StreamingPlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "turn.completed", turn_type: :tool_calls}
      }

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "state.change", state: :running_tools}
      }
    end
  end

  # ============================================================================
  # Passthrough for Unrelated Signals
  # ============================================================================

  describe "handle_signal/2 with unrelated signals" do
    test "passes through unrecognized signal types" do
      agent = build_agent()
      context = build_context(agent)

      signal = make_signal("some.other.signal", %{data: "value"})

      result = StreamingPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result
    end

    test "passes through ai.llm.response (handled by persistence plugin)" do
      agent = build_agent()
      context = build_context(agent)

      signal = make_signal("ai.llm.response", %{result: {:ok, %{text: "Hello"}}})

      result = StreamingPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result
    end

    test "passes through ai.tool.started (handled by tool plugin)" do
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.tool.started", %{
          tool_name: "web_search",
          call_id: "tool-call-1"
        })

      result = StreamingPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result
    end
  end
end
