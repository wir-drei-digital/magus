defmodule Magus.Agents.Plugins.PersistencePluginTest do
  use Magus.DataCase, async: true

  alias Magus.Agents.Plugins.PersistencePlugin
  alias Magus.Agents.Plugins.Support.Helpers

  @conversation_id "persistence-plugin-conv-id"
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
          __strategy__: %{
            active_request_id: @message_id,
            streaming_text: "",
            streaming_thinking: "",
            pending_tool_calls: []
          }
        },
        overrides
      )

    %{id: "conv:#{@conversation_id}", state: base_state}
  end

  defp expected_response_id do
    Helpers.response_id_for_request(@message_id)
  end

  defp expected_turn_response_id(iteration) do
    Helpers.response_id_for_turn(@message_id, iteration)
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

  describe "plugin metadata" do
    test "has correct name and state_key" do
      assert PersistencePlugin.name() == "persistence"
      assert PersistencePlugin.state_key() == :persistence
    end

    test "has signal patterns for response and request lifecycle signals" do
      patterns = PersistencePlugin.signal_patterns()
      assert "ai.llm.response" in patterns
      assert "ai.request.completed" in patterns
      assert "ai.request.failed" in patterns
    end

    test "does not handle streaming or tool signals" do
      patterns = PersistencePlugin.signal_patterns()
      refute "ai.llm.delta" in patterns
      refute "ai.tool.started" in patterns
      refute "ai.tool.result" in patterns
      refute "message.user" in patterns
    end
  end

  # ============================================================================
  # Mount
  # ============================================================================

  describe "mount/2" do
    test "initializes plugin state with config" do
      agent = build_agent()
      {:ok, state} = PersistencePlugin.mount(agent, %{some: :config})

      assert Map.has_key?(state, :config)
      assert state[:config] == %{some: :config}
    end
  end

  # ============================================================================
  # ai.llm.response
  # ============================================================================

  describe "handle_signal/2 with ai.llm.response" do
    test "broadcasts text.complete for a final answer turn" do
      subscribe_to_conversation()
      expected_id = expected_turn_response_id(2)
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.llm.response", %{
          call_id: "call_#{@message_id}_2_llm-1",
          result:
            {:ok,
             %{
               type: :final_answer,
               text: "Hello there.",
               projected_text: "Hello there.",
               tool_calls: []
             }},
          usage: %{input_tokens: 10, output_tokens: 3}
        })

      assert {:ok, :continue} = PersistencePlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{
          type: "text.complete",
          message_id: ^expected_id,
          text: "Hello there."
        }
      }
    end

    test "broadcasts text.complete for a tool-call turn with projected_text" do
      subscribe_to_conversation()
      expected_id = expected_turn_response_id(1)

      agent =
        build_agent(%{
          __strategy__: %{
            active_request_id: @message_id,
            streaming_text: "I'll create a draft for you.",
            streaming_thinking: "",
            pending_tool_calls: []
          }
        })

      context = build_context(agent)

      signal =
        make_signal("ai.llm.response", %{
          call_id: "call_#{@message_id}_1_llm-1",
          result:
            {:ok,
             %{
               type: :tool_calls,
               text: ~s([{"tool_name":"write_draft","arguments":{"title":"The History"}}]),
               projected_text: "I'll create a draft for you.",
               tool_calls: [
                 %{id: "tc-1", name: "write_draft", arguments: %{"title" => "The History"}}
               ]
             }}
        })

      assert {:ok, :continue} = PersistencePlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: payload
      }

      assert payload.type == "text.complete"
      assert payload.message_id == expected_id
      assert payload.text == "I'll create a draft for you."
    end

    test "uses response_id_for_request when no call_id iteration" do
      subscribe_to_conversation()
      expected_id = expected_response_id()
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.llm.response", %{
          request_id: @message_id,
          result: %{
            text: "Simple response.",
            projected_text: "Simple response.",
            tool_calls: []
          },
          usage: %{}
        })

      assert {:ok, :continue} = PersistencePlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{
          type: "text.complete",
          message_id: ^expected_id,
          text: "Simple response."
        }
      }
    end

    test "does not broadcast when message_id is invalid" do
      # Use a unique conversation ID to avoid PubSub cross-contamination
      unique_conv_id = Ash.UUID.generate()
      MagusWeb.Endpoint.subscribe("agents:#{unique_conv_id}")

      # Agent with no active_request_id and no call_id means no message_id
      agent = %{
        id: "conv:#{unique_conv_id}",
        state: %{
          conversation_id: unique_conv_id,
          user_id: @user_id,
          mode: :chat,
          model_keys: %{chat: "test-model"},
          __strategy__: %{
            active_request_id: nil,
            streaming_text: "",
            streaming_thinking: "",
            pending_tool_calls: []
          }
        }
      }

      context = build_context(agent)

      signal =
        make_signal("ai.llm.response", %{
          result: %{text: "Orphaned.", projected_text: "Orphaned.", tool_calls: []}
        })

      assert {:ok, :continue} = PersistencePlugin.handle_signal(signal, context)

      refute_receive %Phoenix.Socket.Broadcast{
                       payload: %{type: "text.complete"}
                     },
                     100
    end

    test "includes custom_agent_opts in text.complete broadcast" do
      subscribe_to_conversation()

      agent =
        build_agent(%{
          custom_agent_id: "agent-42",
          custom_agent_name: "Test Bot",
          __strategy__: %{
            active_request_id: @message_id,
            streaming_text: "",
            streaming_thinking: "",
            pending_tool_calls: []
          }
        })

      context = build_context(agent)

      signal =
        make_signal("ai.llm.response", %{
          request_id: @message_id,
          result: %{text: "From custom agent.", projected_text: "From custom agent."},
          usage: %{}
        })

      assert {:ok, :continue} = PersistencePlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: payload
      }

      assert payload.type == "text.complete"
      assert payload.custom_agent_id == "agent-42"
      assert payload.custom_agent_name == "Test Bot"
    end

    test "drops an empty turn: broadcasts turn.empty and no text.complete" do
      subscribe_to_conversation()
      expected_id = expected_response_id()
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.llm.response", %{
          request_id: @message_id,
          result: %{text: "", projected_text: "", tool_calls: []},
          usage: %{}
        })

      assert {:ok, :continue} = PersistencePlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "turn.empty", message_id: ^expected_id}
      }

      refute_receive %Phoenix.Socket.Broadcast{payload: %{type: "text.complete"}}, 100
    end
  end

  # ============================================================================
  # ai.request.completed
  # ============================================================================

  describe "handle_signal/2 with ai.request.completed" do
    test "broadcasts state.change(:idle) and response.complete" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.request.completed", %{
          request_id: "req-1",
          result: "Final answer"
        })

      assert {:ok, :continue} = PersistencePlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "state.change", state: :idle}
      }

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "response.complete", triggering_message_id: "req-1"}
      }
    end

    test "broadcasts response.complete without triggering_message_id when request_id missing" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)

      signal = make_signal("ai.request.completed", %{result: "Done"})

      assert {:ok, :continue} = PersistencePlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "state.change", state: :idle}
      }

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: response_payload
      }

      assert response_payload.type == "response.complete"
      refute Map.has_key?(response_payload, :triggering_message_id)
    end
  end

  # ============================================================================
  # ai.request.failed
  # ============================================================================

  describe "handle_signal/2 with ai.request.failed" do
    test "broadcasts error, state.change(:idle), and response.complete for failures" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.request.failed", %{
          request_id: "req-1",
          error: "LLM provider error"
        })

      assert {:ok, :continue} = PersistencePlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "error", error_type: :request_failed}
      }

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "state.change", state: :idle}
      }

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "response.complete"}
      }
    end

    test "suppresses error broadcast for cancellations" do
      # Use a unique conversation ID to avoid PubSub cross-contamination
      unique_conv_id = Ash.UUID.generate()
      MagusWeb.Endpoint.subscribe("agents:#{unique_conv_id}")

      agent = %{
        id: "conv:#{unique_conv_id}",
        state: %{
          conversation_id: unique_conv_id,
          user_id: @user_id,
          mode: :chat,
          model_keys: %{chat: "test-model"},
          __strategy__: %{
            active_request_id: @message_id,
            streaming_text: "",
            streaming_thinking: "",
            pending_tool_calls: []
          }
        }
      }

      context = build_context(agent)

      signal =
        make_signal("ai.request.failed", %{
          request_id: "req-1",
          error: {:cancelled, :user_cancelled}
        })

      assert {:ok, :continue} = PersistencePlugin.handle_signal(signal, context)

      # Should get state.change and response.complete but NOT an error broadcast
      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "state.change", state: :idle}
      }

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "response.complete"}
      }

      # No error broadcast for cancellations
      refute_receive %Phoenix.Socket.Broadcast{
                       payload: %{type: "error"}
                     },
                     100
    end

    test "uses parent_message_id as triggering_message_id when request_id is nil" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)

      signal = make_signal("ai.request.failed", %{error: "Something broke"})

      assert {:ok, :continue} = PersistencePlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "response.complete", triggering_message_id: @message_id}
      }
    end

    test "derives message_id from active_request_id for error broadcast" do
      subscribe_to_conversation()
      expected_id = expected_response_id()
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.request.failed", %{
          error: "Model overloaded"
        })

      assert {:ok, :continue} = PersistencePlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "error", message_id: ^expected_id, error_type: :request_failed}
      }
    end
  end

  # ============================================================================
  # Passthrough for unrelated signals
  # ============================================================================

  describe "handle_signal/2 with unmatched signal types" do
    test "passes through unrecognized signal types" do
      agent = build_agent()
      context = build_context(agent)

      signal = make_signal("some.other.signal", %{data: "value"})

      assert {:ok, :continue} = PersistencePlugin.handle_signal(signal, context)
    end

    test "passes through streaming signals (not our responsibility)" do
      agent = build_agent()
      context = build_context(agent)

      signal = make_signal("ai.llm.delta", %{delta: "hello"})

      assert {:ok, :continue} = PersistencePlugin.handle_signal(signal, context)
    end

    test "passes through tool signals (not our responsibility)" do
      agent = build_agent()
      context = build_context(agent)

      signal = make_signal("ai.tool.started", %{tool_name: "web_search"})

      assert {:ok, :continue} = PersistencePlugin.handle_signal(signal, context)
    end
  end
end
