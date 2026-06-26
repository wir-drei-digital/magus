defmodule Magus.Agents.IntegrationTest do
  use Magus.DataCase, async: false

  require Ash.Query
  import Magus.Generators

  alias Magus.Agents.ConversationAgent
  alias Magus.Agents.Plugins.InboundPlugin
  alias Magus.Agents.Plugins.StreamingPlugin
  alias Magus.Agents.Plugins.PersistencePlugin
  alias Magus.Agents.Plugins.ToolEventPlugin
  alias Magus.Agents.Plugins.Support.Helpers
  alias Magus.Agents.Plugins.Support.ModelResolver
  alias Magus.Agents.Persistence.PostgresStore
  alias Magus.Agents.Persistence.Checkpoint, as: Persistence

  @moduledoc """
  Integration tests for the Jido agent system with ReAct.Strategy + composable plugins.

  Tests the full agent lifecycle: configuration, signal routing, persistence,
  PubSub broadcast integration, and state round-trips. Tests are organized by
  what can be verified without external services (LLM API keys).

  Tests that require actual LLM calls are tagged with `@tag :external`.
  """

  # Helper to set agent state, unwrapping the {:ok, agent} tuple
  defp set_state!(agent, state) do
    {:ok, updated} = Jido.Agent.set(agent, state)
    updated
  end

  # Build a context map matching what AgentServer passes to handle_signal
  defp build_plugin_context(agent, plugin \\ InboundPlugin) do
    %{
      agent: agent,
      agent_module: ConversationAgent,
      plugin: plugin,
      plugin_spec: nil,
      plugin_instance: nil,
      config: %{}
    }
  end

  # Subscribe to PubSub broadcasts for a conversation
  defp subscribe_to_agent_broadcasts(conversation_id) do
    MagusWeb.Endpoint.subscribe("agents:#{conversation_id}")
  end

  # Set up a user with a free plan subscription so usage limit checks pass
  defp setup_user_with_subscription(user) do
    free_plan = ensure_free_plan()

    {:ok, _subscription} =
      Magus.Usage.create_user_subscription(
        %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
        authorize?: false
      )

    :ok
  end

  setup do
    user = generate(user())
    conversation = generate(conversation(actor: user))
    setup_user_with_subscription(user)
    {:ok, user: user, conversation: conversation}
  end

  # ==========================================================================
  # Agent Configuration and Startup
  # ==========================================================================

  describe "agent configuration" do
    test "ConversationAgent uses ReactStrategy" do
      assert ConversationAgent.strategy() == Magus.Agents.Strategies.ReactStrategy
    end

    test "ConversationAgent has all composable plugins registered" do
      plugins = ConversationAgent.plugins()

      assert Magus.Agents.Plugins.InboundPlugin in plugins
      assert Magus.Agents.Plugins.StreamingPlugin in plugins
      assert Magus.Agents.Plugins.PersistencePlugin in plugins
      assert Magus.Agents.Plugins.ToolEventPlugin in plugins
      assert Magus.Agents.Plugins.UsagePlugin in plugins
    end

    test "ConversationAgent strategy options are correctly configured" do
      opts = ConversationAgent.strategy_opts()

      # Static :tools is intentionally empty; ToolBuilder injects the per-turn
      # toolset via Preflight (see Magus.Agents.Tools.ToolBuilder).
      assert Keyword.get(opts, :tools) == []
      # model is NOT in strategy opts — it comes from agent.state[:model] instead
      assert Keyword.get(opts, :model) == nil

      # max_iterations is NOT in strategy opts — strategy falls back to Magus.Config.max_iterations/0
      assert Keyword.get(opts, :max_iterations) == nil
      assert Keyword.get(opts, :streaming) == true
      assert Keyword.get(opts, :tool_timeout_ms) == 120_000
      assert Keyword.get(opts, :tool_max_retries) == 1

      # Observability signals enabled
      observability = Keyword.get(opts, :observability)
      assert observability.emit_signals? == true
      assert observability.emit_lifecycle_signals? == true
      assert observability.emit_llm_deltas? == true
    end

    test "new agent initializes plugin state for all plugins" do
      agent = ConversationAgent.new(id: "conv:test-init")

      assert is_map(agent.state[:inbound])
      assert is_map(agent.state[:streaming])
      assert is_map(agent.state[:persistence])
      assert is_map(agent.state[:tool_events])
      assert is_map(agent.state[:usage])
    end

    test "new agent schema defaults are correct" do
      agent = ConversationAgent.new(id: "conv:test-defaults")

      assert agent.state.mode == :chat
      assert agent.state.model_keys == %{}
    end
  end

  # ==========================================================================
  # Plugin Signal Routing (Inbound)
  # ==========================================================================

  describe "InboundPlugin signal routing - message.user" do
    test "transforms message.user to ai.react.query for chat mode", %{
      user: user,
      conversation: conversation
    } do
      agent = ConversationAgent.new(id: "conv:#{conversation.id}")

      agent =
        set_state!(agent, %{
          conversation_id: conversation.id,
          user_id: user.id,
          mode: :chat,
          model_keys: %{}
        })

      context = build_plugin_context(agent)

      signal =
        Jido.Signal.new!("message.user", %{
          text: "Hello, world!",
          message_id: "msg-123"
        })

      result = InboundPlugin.handle_signal(signal, context)

      # Should transform to ai.react.query signal
      assert {:ok, {:continue, react_signal}} = result
      assert %Jido.Signal{} = react_signal
      assert react_signal.type == "ai.react.query"
      assert react_signal.data[:query] == "Hello, world!"
      assert react_signal.data[:request_id] == "msg-123"
      assert is_map(react_signal.data)
      assert react_signal.data[:tool_context][:user_id] == user.id
      assert react_signal.data[:tool_context][:conversation_id] == conversation.id
    end

    test "passes runtime overrides from message.user to ai.react.query", %{
      user: user,
      conversation: conversation
    } do
      agent = ConversationAgent.new(id: "conv:#{conversation.id}")

      agent =
        set_state!(agent, %{
          conversation_id: conversation.id,
          user_id: user.id,
          mode: :chat,
          model_keys: %{chat: "test-model"}
        })

      context = build_plugin_context(agent)

      signal =
        Jido.Signal.new!("message.user", %{
          text: "Use overrides",
          message_id: "msg-override-1",
          max_iterations: 4,
          llm_opts: %{temperature: 0.6}
        })

      assert {:ok, {:continue, react_signal}} = InboundPlugin.handle_signal(signal, context)
      assert react_signal.type == "ai.react.query"
      assert react_signal.data[:model] == "test-model"
      assert react_signal.data[:max_iterations] == 4
      assert react_signal.data[:llm_opts] == %{temperature: 0.6}
    end

    test "halts signal for image_generation mode (media bypass)", %{
      user: user,
      conversation: conversation
    } do
      agent = ConversationAgent.new(id: "conv:#{conversation.id}")

      agent =
        set_state!(agent, %{
          conversation_id: conversation.id,
          user_id: user.id,
          mode: :image_generation,
          model_keys: %{}
        })

      context = build_plugin_context(agent)

      signal =
        Jido.Signal.new!("message.user", %{
          text: "Generate an image of a cat",
          mode: :image_generation,
          message_id: "msg-img"
        })

      result = InboundPlugin.handle_signal(signal, context)

      # Media generation bypass should halt propagation
      assert {:ok, {:override, Jido.Actions.Control.Noop}} = result
    end

    test "halts signal for video_generation mode (media bypass)", %{
      user: user,
      conversation: conversation
    } do
      agent = ConversationAgent.new(id: "conv:#{conversation.id}")

      agent =
        set_state!(agent, %{
          conversation_id: conversation.id,
          user_id: user.id,
          mode: :video_generation,
          model_keys: %{}
        })

      context = build_plugin_context(agent)

      signal =
        Jido.Signal.new!("message.user", %{
          text: "Generate a video",
          mode: :video_generation,
          message_id: "msg-vid"
        })

      result = InboundPlugin.handle_signal(signal, context)

      # Media generation bypass should halt propagation
      assert {:ok, {:override, Jido.Actions.Control.Noop}} = result
    end
  end

  describe "InboundPlugin signal routing - message.cancel" do
    test "transforms message.cancel to ai.react.cancel" do
      agent = ConversationAgent.new(id: "conv:cancel-test")

      agent =
        set_state!(agent, %{
          conversation_id: "conv-cancel",
          user_id: "user-cancel",
          mode: :chat
        })

      context = build_plugin_context(agent)

      signal = Jido.Signal.new!("message.cancel", %{})

      result = InboundPlugin.handle_signal(signal, context)

      assert {:ok, {:continue, cancel_signal}} = result
      assert %Jido.Signal{} = cancel_signal
      assert cancel_signal.type == "ai.react.cancel"
      assert cancel_signal.data[:reason] == :user_cancelled
    end
  end

  # ==========================================================================
  # Plugin Signal Translation (Outbound: ReAct -> PubSub)
  # ==========================================================================

  describe "plugin outbound signal translation" do
    test "ai.llm.turn.started broadcasts turn.started via PubSub", %{conversation: conversation} do
      subscribe_to_agent_broadcasts(conversation.id)
      agent = ConversationAgent.new(id: "conv:#{conversation.id}")

      agent =
        set_state!(agent, %{
          conversation_id: conversation.id,
          user_id: "user-turn-started",
          mode: :chat
        })

      context = build_plugin_context(agent, StreamingPlugin)

      signal =
        Jido.Signal.new!("ai.llm.turn.started", %{
          request_id: "msg-turn-started",
          turn_id: "msg-turn-started:1",
          iteration: 1
        })

      assert {:ok, :continue} = StreamingPlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "turn.started", turn_id: "msg-turn-started:1", iteration: 1}
      }
    end

    test "ai.llm.turn.completed broadcasts turn.completed and running_tools for tool turn", %{
      conversation: conversation
    } do
      subscribe_to_agent_broadcasts(conversation.id)
      agent = ConversationAgent.new(id: "conv:#{conversation.id}")

      agent =
        set_state!(agent, %{
          conversation_id: conversation.id,
          user_id: "user-turn-completed",
          mode: :chat
        })

      context = build_plugin_context(agent, StreamingPlugin)

      signal =
        Jido.Signal.new!("ai.llm.turn.completed", %{
          request_id: "msg-turn-completed",
          turn_id: "msg-turn-completed:1",
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

    test "ai.llm.delta broadcasts text.chunk via PubSub", %{conversation: conversation} do
      subscribe_to_agent_broadcasts(conversation.id)

      agent = ConversationAgent.new(id: "conv:#{conversation.id}")

      request_id = "msg-delta-test"

      agent =
        set_state!(agent, %{
          conversation_id: conversation.id,
          user_id: "user-delta",
          mode: :chat,
          __strategy__: %{active_request_id: request_id}
        })

      context = build_plugin_context(agent, StreamingPlugin)

      signal =
        Jido.Signal.new!("ai.llm.delta", %{
          request_id: request_id,
          delta: " world",
          chunk_type: :content
        })

      result = StreamingPlugin.handle_signal(signal, context)

      # Should continue (not halt) so ReAct strategy also sees it
      assert {:ok, :continue} = result

      # Verify PubSub broadcast
      expected_id = Helpers.response_id_for_request(request_id)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: topic,
        event: "agent_signal",
        payload: %{type: "text.chunk"} = payload
      }

      assert topic == "agents:#{conversation.id}"
      assert payload.delta == " world"
      assert payload.message_id == expected_id
    end

    test "ai.llm.delta with thinking chunk broadcasts thinking.chunk", %{
      conversation: conversation
    } do
      subscribe_to_agent_broadcasts(conversation.id)

      agent = ConversationAgent.new(id: "conv:#{conversation.id}")

      agent =
        set_state!(agent, %{
          conversation_id: conversation.id,
          user_id: "user-think",
          mode: :chat,
          conversation_skill: %{
            message_id: "msg-think-test",
            accumulated_text: "",
            accumulated_thinking: "Let me think"
          }
        })

      context = build_plugin_context(agent, StreamingPlugin)

      signal =
        Jido.Signal.new!("ai.llm.delta", %{
          request_id: "msg-think-test",
          delta: " about this",
          chunk_type: :thinking
        })

      result = StreamingPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "thinking.chunk"} = payload
      }

      assert payload.delta == " about this"
    end

    test "ai.request.started broadcasts state.change(:thinking)", %{conversation: conversation} do
      subscribe_to_agent_broadcasts(conversation.id)

      agent = ConversationAgent.new(id: "conv:#{conversation.id}")

      agent =
        set_state!(agent, %{
          conversation_id: conversation.id,
          user_id: "user-started",
          mode: :chat
        })

      context = build_plugin_context(agent, StreamingPlugin)

      signal = Jido.Signal.new!("ai.request.started", %{})

      result = StreamingPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "state.change", state: :thinking}
      }
    end

    test "ai.request.completed broadcasts state.change(:idle) and response.complete", %{
      conversation: conversation
    } do
      subscribe_to_agent_broadcasts(conversation.id)

      agent = ConversationAgent.new(id: "conv:#{conversation.id}")

      agent =
        set_state!(agent, %{
          conversation_id: conversation.id,
          user_id: "user-completed",
          mode: :chat,
          conversation_skill: %{
            message_id: "msg-complete",
            accumulated_text: "final response",
            accumulated_thinking: ""
          }
        })

      context = build_plugin_context(agent, PersistencePlugin)

      signal =
        Jido.Signal.new!("ai.request.completed", %{
          result: %{content: "final response"}
        })

      result = PersistencePlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      # Should broadcast idle state
      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "state.change", state: :idle}
      }

      # Should broadcast response.complete
      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "response.complete"}
      }
    end

    test "ai.request.failed broadcasts error and goes idle", %{conversation: conversation} do
      subscribe_to_agent_broadcasts(conversation.id)

      agent = ConversationAgent.new(id: "conv:#{conversation.id}")

      agent =
        set_state!(agent, %{
          conversation_id: conversation.id,
          user_id: "user-failed",
          mode: :chat,
          conversation_skill: %{
            message_id: "msg-fail",
            accumulated_text: "",
            accumulated_thinking: ""
          }
        })

      context = build_plugin_context(agent, PersistencePlugin)

      signal =
        Jido.Signal.new!("ai.request.failed", %{
          error: "LLM API error: rate limited"
        })

      result = PersistencePlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      # Should broadcast error
      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "error", error_type: :request_failed}
      }

      # Should broadcast idle state
      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "state.change", state: :idle}
      }

      # Should broadcast response.complete
      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "response.complete"}
      }
    end

    test "ai.request.failed with cancellation does not broadcast error", %{
      conversation: conversation
    } do
      subscribe_to_agent_broadcasts(conversation.id)

      agent = ConversationAgent.new(id: "conv:#{conversation.id}")

      agent =
        set_state!(agent, %{
          conversation_id: conversation.id,
          user_id: "user-cancel",
          mode: :chat,
          conversation_skill: %{
            message_id: "msg-cancel",
            accumulated_text: "",
            accumulated_thinking: ""
          }
        })

      context = build_plugin_context(agent, PersistencePlugin)

      signal =
        Jido.Signal.new!("ai.request.failed", %{
          error: {:cancelled, :user_cancelled}
        })

      result = PersistencePlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      # Should NOT broadcast an error for cancellation
      refute_receive %Phoenix.Socket.Broadcast{
                       event: "agent_signal",
                       payload: %{type: "error"}
                     },
                     100

      # Should still broadcast idle state and response.complete
      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "state.change", state: :idle}
      }

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "response.complete"}
      }
    end

    test "ai.tool.result broadcasts tool.complete", %{conversation: conversation} do
      subscribe_to_agent_broadcasts(conversation.id)

      agent = ConversationAgent.new(id: "conv:#{conversation.id}")

      agent =
        set_state!(agent, %{
          conversation_id: conversation.id,
          user_id: "user-tool",
          mode: :chat
        })

      context = build_plugin_context(agent, ToolEventPlugin)

      signal =
        Jido.Signal.new!("ai.tool.result", %{
          tool_name: "web_search",
          call_id: "call-123",
          result: {:ok, %{results: ["result1", "result2"]}}
        })

      result = ToolEventPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "tool.complete"} = payload
      }

      assert payload.tool_name == "web_search"
      assert payload.event_id == Helpers.tool_event_id_for_call_id("call-123")
      assert payload.status == :success
    end

    test "ai.tool.result with error broadcasts tool.complete with error status", %{
      conversation: conversation
    } do
      subscribe_to_agent_broadcasts(conversation.id)

      agent = ConversationAgent.new(id: "conv:#{conversation.id}")

      agent =
        set_state!(agent, %{
          conversation_id: conversation.id,
          user_id: "user-tool-err",
          mode: :chat
        })

      context = build_plugin_context(agent, ToolEventPlugin)

      signal =
        Jido.Signal.new!("ai.tool.result", %{
          tool_name: "web_search",
          call_id: "call-err",
          result: {:error, "search failed"}
        })

      result = ToolEventPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "tool.complete"} = payload
      }

      assert payload.status == :error
      assert payload.error != nil
      assert payload.event_id == Helpers.tool_event_id_for_call_id("call-err")
    end

    test "unhandled signal types pass through without modification" do
      agent = ConversationAgent.new(id: "conv:unhandled")

      agent =
        set_state!(agent, %{
          conversation_id: "conv-unhandled",
          user_id: "user-unhandled",
          mode: :chat
        })

      context = build_plugin_context(agent)

      signal = Jido.Signal.new!("some.unknown.signal", %{data: "test"})

      result = InboundPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result
    end
  end

  # ==========================================================================
  # Agent State Persistence (PostgresStore)
  # ==========================================================================

  describe "agent state persistence" do
    test "agent state persists to database", %{conversation: conversation} do
      agent_id = "conv:#{conversation.id}"

      {:ok, _state} =
        Magus.Agents.AgentState
        |> Ash.Changeset.for_create(:upsert, %{
          agent_module: "Magus.Agents.ConversationAgent",
          agent_id: agent_id,
          state_data: %{
            conversation_id: conversation.id,
            user_id: conversation.user_id,
            mode: :chat
          }
        })
        |> Ash.create(authorize?: false)

      # Verify we can read it back
      {:ok, loaded_state} =
        Magus.Agents.AgentState
        |> Ash.Query.filter(
          agent_module == "Magus.Agents.ConversationAgent" and agent_id == ^agent_id
        )
        |> Ash.read_one(authorize?: false)

      assert loaded_state != nil
      assert loaded_state.agent_id == agent_id
      # JSON serialization converts atoms to strings
      assert loaded_state.state_data["mode"] == "chat"
    end

    test "postgres store put/get/delete cycle", %{conversation: conversation} do
      agent_id = "conv:#{conversation.id}"
      module = ConversationAgent
      key = {module, agent_id}

      checkpoint = %{
        version: 1,
        id: agent_id,
        state: %{
          conversation_id: conversation.id,
          user_id: conversation.user_id,
          mode: :chat
        }
      }

      assert :ok = PostgresStore.put_checkpoint(key, checkpoint, [])

      # Retrieve
      assert {:ok, data} = PostgresStore.get_checkpoint(key, [])
      assert data[:id] == agent_id
      assert data[:version] == 1

      # Delete
      assert :ok = PostgresStore.delete_checkpoint(key, [])

      # Verify deleted
      assert :not_found = PostgresStore.get_checkpoint(key, [])
    end
  end

  # ==========================================================================
  # Checkpoint/Restore Round-Trip
  # ==========================================================================

  describe "checkpoint/restore round-trip" do
    test "agent state survives full checkpoint -> JSON -> restore cycle" do
      original = ConversationAgent.new(id: "conv:roundtrip-test")

      original =
        set_state!(original, %{
          conversation_id: "conv-roundtrip",
          user_id: "user-roundtrip",
          model_keys: %{
            chat: "openrouter:claude-3",
            image: "openrouter:flux",
            video: "aimlapi:kling"
          },
          mode: :video_generation
        })

      # Checkpoint
      {:ok, checkpoint} = ConversationAgent.checkpoint(original, %{})

      # Simulate JSON round-trip (what happens in DB)
      json = Jason.encode!(checkpoint)
      deserialized = Jason.decode!(json)

      # Restore
      {:ok, restored} = ConversationAgent.restore(deserialized, %{})

      # Verify essential state
      assert restored.id == original.id
      assert restored.state.conversation_id == "conv-roundtrip"
      assert restored.state.user_id == "user-roundtrip"
      assert restored.state.mode == :video_generation

      assert restored.state.model_keys == %{
               chat: "openrouter:claude-3",
               image: "openrouter:flux",
               video: "aimlapi:kling"
             }
    end

    test "agent survives full hibernate/thaw cycle via PostgresStore" do
      agent_id = "conv:hibernate-cycle-#{System.unique_integer([:positive])}"

      agent = ConversationAgent.new(id: agent_id)

      agent =
        set_state!(agent, %{
          conversation_id: "conv-hibernate",
          user_id: "user-hibernate",
          model_keys: %{chat: "model-1", image: "model-2"},
          mode: :reasoning
        })

      storage_config = {PostgresStore, []}

      # Hibernate
      :ok = Jido.Persist.hibernate(storage_config, ConversationAgent, agent_id, agent)

      # Thaw
      {:ok, restored} = Jido.Persist.thaw(storage_config, ConversationAgent, agent_id)

      assert restored.id == agent_id
      assert restored.state.conversation_id == "conv-hibernate"
      assert restored.state.user_id == "user-hibernate"
      assert restored.state.mode == :reasoning
      assert restored.state.model_keys == %{chat: "model-1", image: "model-2"}

      # Thawed agent should still be a proper Jido.Agent struct
      assert %Jido.Agent{} = restored
      assert restored.name == "conversation"
    end

    test "thawed agent retains module configuration" do
      agent_id = "conv:module-check-#{System.unique_integer([:positive])}"

      agent = ConversationAgent.new(id: agent_id)

      agent =
        set_state!(agent, %{
          conversation_id: "test-conv",
          user_id: "test-user",
          mode: :chat
        })

      storage_config = {PostgresStore, []}
      :ok = Jido.Persist.hibernate(storage_config, ConversationAgent, agent_id, agent)
      {:ok, thawed} = Jido.Persist.thaw(storage_config, ConversationAgent, agent_id)

      # Module-level configuration should be available after thaw
      assert ConversationAgent.strategy() == Magus.Agents.Strategies.ReactStrategy
      assert Magus.Agents.Plugins.InboundPlugin in ConversationAgent.plugins()

      # State should be updatable
      {:ok, updated} = Jido.Agent.set(thawed, %{mode: :reasoning})
      assert updated.state.mode == :reasoning
    end

    test "legacy flat format checkpoint restores correctly" do
      agent_id = "conv:legacy-#{System.unique_integer([:positive])}"
      key = {ConversationAgent, agent_id}

      # Simulate legacy flat format that old agents might have stored
      legacy_checkpoint = %{
        "id" => agent_id,
        "conversation_id" => "conv-legacy",
        "user_id" => "user-legacy",
        "model_key" => "openrouter:gpt-4",
        "mode" => "chat"
      }

      :ok = PostgresStore.put_checkpoint(key, legacy_checkpoint, [])
      {:ok, data} = PostgresStore.get_checkpoint(key, [])
      {:ok, agent} = ConversationAgent.restore(data, %{})

      assert agent.id == agent_id
      assert agent.state.conversation_id == "conv-legacy"
      assert agent.state.user_id == "user-legacy"
      # Legacy model_key should be converted to model_keys with :chat key
      assert agent.state.model_keys == %{chat: "openrouter:gpt-4"}
      assert agent.state.mode == :chat
    end
  end

  # ==========================================================================
  # Persistence Module Helpers
  # ==========================================================================

  describe "Persistence helpers" do
    test "get_value handles both atom and string keys" do
      assert Persistence.get_value(%{user_id: "123"}, :user_id) == "123"
      assert Persistence.get_value(%{"user_id" => "123"}, :user_id) == "123"
      assert Persistence.get_value(%{}, :user_id) == nil
    end

    test "wrap_checkpoint produces canonical format" do
      {:ok, checkpoint} =
        Persistence.wrap_checkpoint(ConversationAgent, "conv:test", %{
          user_id: "u1",
          mode: :chat
        })

      assert checkpoint.version == 1
      assert checkpoint.agent_module == ConversationAgent
      assert checkpoint.id == "conv:test"
      assert checkpoint.state == %{user_id: "u1", mode: :chat}
    end

    test "extract_state handles canonical format with nested state" do
      data = %{"version" => 1, "state" => %{"user_id" => "u1"}}
      assert Persistence.extract_state(data) == %{"user_id" => "u1"}
    end

    test "extract_state handles flat format (legacy)" do
      data = %{"user_id" => "u1", "conversation_id" => "conv-1"}
      assert Persistence.extract_state(data) == data
    end

    test "validate_required succeeds when all fields present" do
      data = %{"id" => "x"}
      state = %{"user_id" => "u", "conversation_id" => "c"}

      assert :ok =
               Persistence.validate_required(data, state,
                 data: :id,
                 state: :user_id,
                 state: :conversation_id
               )
    end

    test "validate_required fails for missing field" do
      data = %{"id" => "x"}
      state = %{}

      assert {:error, {:missing_field, :user_id}} =
               Persistence.validate_required(data, state,
                 data: :id,
                 state: :user_id
               )
    end

    test "validate_required fails for empty string field" do
      data = %{"id" => ""}
      state = %{"user_id" => "u"}

      assert {:error, {:missing_field, :id}} =
               Persistence.validate_required(data, state,
                 data: :id,
                 state: :user_id
               )
    end

    test "parse_datetime handles various formats" do
      assert Persistence.parse_datetime(nil) == nil
      assert %DateTime{} = Persistence.parse_datetime(DateTime.utc_now())
      assert %DateTime{} = Persistence.parse_datetime("2026-01-15T10:30:00Z")
      assert Persistence.parse_datetime("not a date") == nil
      assert Persistence.parse_datetime(42) == nil
    end
  end

  # ==========================================================================
  # ModelResolver Resolution
  # ==========================================================================

  describe "ModelResolver model resolution" do
    test "resolve_model uses selected_model_id when provided" do
      model = generate(model(key: "test/resolution-model"))

      resolved = ModelResolver.resolve_model(%{}, :chat, model.id)

      assert resolved.key == "test/resolution-model"
    end

    test "resolve_model falls back to model_keys when no selected_model_id" do
      model = generate(model(key: "test/keyed-model"))

      resolved = ModelResolver.resolve_model(%{chat: model.key}, :chat, nil)

      assert resolved.key == "test/keyed-model"
    end

    test "resolve_model returns fallback model when nothing matches" do
      resolved = ModelResolver.resolve_model(%{}, :chat, nil)

      # Should return the fallback model
      assert resolved.name == "Default"
      assert resolved.supports_tools? == true
    end

    test "resolve_model uses image key for image_generation mode" do
      image_model = generate(model(key: "test/image-model"))
      chat_model = generate(model(key: "test/chat-model"))

      model_keys = %{chat: chat_model.key, image: image_model.key}

      resolved = ModelResolver.resolve_model(model_keys, :image_generation, nil)
      assert resolved.key == "test/image-model"
    end

    test "resolve_model uses video key for video_generation mode" do
      video_model = generate(model(key: "test/video-model"))
      model_keys = %{video: video_model.key}

      resolved = ModelResolver.resolve_model(model_keys, :video_generation, nil)
      assert resolved.key == "test/video-model"
    end

    test "resolve_model falls back to chat key for image mode when no image key" do
      chat_model = generate(model(key: "test/fallback-chat"))
      model_keys = %{chat: chat_model.key}

      resolved = ModelResolver.resolve_model(model_keys, :image_generation, nil)
      assert resolved.key == "test/fallback-chat"
    end
  end

  # ==========================================================================
  # Signals Module
  # ==========================================================================

  describe "Signals PubSub integration" do
    test "text_chunk broadcasts to correct topic", %{conversation: conversation} do
      subscribe_to_agent_broadcasts(conversation.id)

      Magus.Agents.Signals.text_chunk(conversation.id, "msg-1", "Hello", " world")

      assert_receive %Phoenix.Socket.Broadcast{
        topic: topic,
        event: "agent_signal",
        payload: %{type: "text.chunk", message_id: "msg-1", text: "Hello", delta: " world"}
      }

      assert topic == "agents:#{conversation.id}"
    end

    test "state_change broadcasts to correct topic", %{conversation: conversation} do
      subscribe_to_agent_broadcasts(conversation.id)

      Magus.Agents.Signals.state_change(conversation.id, :thinking)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "state.change", state: :thinking}
      }
    end

    test "error broadcasts to correct topic", %{conversation: conversation} do
      subscribe_to_agent_broadcasts(conversation.id)

      Magus.Agents.Signals.error(conversation.id, "msg-err", :rate_limit, "Too many requests")

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{
          type: "error",
          message_id: "msg-err",
          error_type: :rate_limit,
          error_message: "Too many requests"
        }
      }
    end

    test "tool start/complete lifecycle broadcasts", %{conversation: conversation} do
      subscribe_to_agent_broadcasts(conversation.id)

      Magus.Agents.Signals.broadcast_tool_start(
        conversation.id,
        "evt-1",
        "web_search",
        "Searching the web...",
        %{query: "test"}
      )

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{
          type: "tool.start",
          event_id: "evt-1",
          tool_name: "web_search",
          display_name: "Searching the web..."
        }
      }

      Magus.Agents.Signals.broadcast_tool_complete(
        conversation.id,
        "evt-1",
        "web_search",
        :success,
        "Found 3 results",
        150,
        nil
      )

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{
          type: "tool.complete",
          event_id: "evt-1",
          tool_name: "web_search",
          status: :success,
          output_summary: "Found 3 results"
        }
      }
    end

    test "emit_tool_progress works with proper context", %{conversation: conversation} do
      subscribe_to_agent_broadcasts(conversation.id)

      context = %{
        __conversation_id__: conversation.id,
        __event_id__: "evt-progress",
        __tool_name__: "web_search"
      }

      assert :ok =
               Magus.Agents.Signals.emit_tool_progress(context, :searching, %{query: "test"})

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{
          type: "tool.progress",
          event_id: "evt-progress",
          tool_name: "web_search",
          progress_type: :searching
        }
      }
    end

    test "emit_tool_progress returns :error when context is incomplete" do
      incomplete_context = %{__conversation_id__: "conv-1"}

      assert :error = Magus.Agents.Signals.emit_tool_progress(incomplete_context, :searching)
    end

    test "tool step lifecycle broadcasts", %{conversation: conversation} do
      subscribe_to_agent_broadcasts(conversation.id)

      context = %{
        __conversation_id__: conversation.id,
        __event_id__: "evt-steps",
        __tool_name__: "test_tool"
      }

      # Step start
      {:ok, step_id} =
        Magus.Agents.Signals.emit_tool_step_start(context, 0, "Searching web")

      assert step_id == "evt-steps-step-0"

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "tool.step.start", step_index: 0, label: "Searching web"}
      }

      # Step progress
      :ok =
        Magus.Agents.Signals.emit_tool_step_progress(context, 0, "Found 3 results")

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "tool.step.progress", content: "Found 3 results"}
      }

      # Step complete
      :ok = Magus.Agents.Signals.emit_tool_step_complete(context, 0)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "agent_signal",
        payload: %{type: "tool.step.complete", status: :complete}
      }
    end
  end

  # ==========================================================================
  # End-to-End: User Message -> Agent System
  # ==========================================================================

  describe "end-to-end message flow" do
    test "sending a user message creates the message record", %{
      user: user,
      conversation: conversation
    } do
      {:ok, message} =
        Magus.Chat.send_user_message(
          %{
            text: "Hello, agent!",
            conversation_id: conversation.id
          },
          actor: user
        )

      assert message.role == :user
      assert message.text == "Hello, agent!"
      assert message.conversation_id == conversation.id

      # Verify the message was persisted
      {:ok, messages} =
        Magus.Chat.Message
        |> Ash.Query.filter(conversation_id == ^conversation.id)
        |> Ash.read(authorize?: false)

      assert length(messages) >= 1
      assert Enum.any?(messages, &(&1.text == "Hello, agent!"))
    end
  end

  # ==========================================================================
  # Multiple Agent Isolation
  # ==========================================================================

  describe "multiple agent isolation" do
    test "separate agents maintain independent state" do
      agent1 = ConversationAgent.new(id: "conv:agent-1")
      agent2 = ConversationAgent.new(id: "conv:agent-2")

      agent1 =
        set_state!(agent1, %{
          conversation_id: "conv-1",
          user_id: "user-1",
          mode: :chat,
          model_keys: %{chat: "model-a"}
        })

      agent2 =
        set_state!(agent2, %{
          conversation_id: "conv-2",
          user_id: "user-2",
          mode: :reasoning,
          model_keys: %{chat: "model-b"}
        })

      assert agent1.state.conversation_id == "conv-1"
      assert agent2.state.conversation_id == "conv-2"
      assert agent1.state.mode == :chat
      assert agent2.state.mode == :reasoning
      assert agent1.state.model_keys == %{chat: "model-a"}
      assert agent2.state.model_keys == %{chat: "model-b"}
    end

    test "separate agents persist and restore independently" do
      storage_config = {PostgresStore, []}

      agent1_id = "conv:iso-1-#{System.unique_integer([:positive])}"
      agent2_id = "conv:iso-2-#{System.unique_integer([:positive])}"

      agent1 = ConversationAgent.new(id: agent1_id)

      agent1 =
        set_state!(agent1, %{
          conversation_id: "conv-iso-1",
          user_id: "user-iso-1",
          mode: :chat
        })

      agent2 = ConversationAgent.new(id: agent2_id)

      agent2 =
        set_state!(agent2, %{
          conversation_id: "conv-iso-2",
          user_id: "user-iso-2",
          mode: :search
        })

      # Hibernate both
      :ok = Jido.Persist.hibernate(storage_config, ConversationAgent, agent1_id, agent1)
      :ok = Jido.Persist.hibernate(storage_config, ConversationAgent, agent2_id, agent2)

      # Thaw and verify independence
      {:ok, restored1} = Jido.Persist.thaw(storage_config, ConversationAgent, agent1_id)
      {:ok, restored2} = Jido.Persist.thaw(storage_config, ConversationAgent, agent2_id)

      assert restored1.state.conversation_id == "conv-iso-1"
      assert restored1.state.mode == :chat
      assert restored2.state.conversation_id == "conv-iso-2"
      assert restored2.state.mode == :search
    end
  end

  # ==========================================================================
  # Signal Flow: Conversation ID Extraction
  # ==========================================================================

  describe "conversation ID extraction" do
    test "extracts conversation_id from agent state when available" do
      agent = ConversationAgent.new(id: "conv:from-state")

      agent =
        set_state!(agent, %{
          conversation_id: "state-conv-id",
          user_id: "user-extract",
          mode: :chat
        })

      context = build_plugin_context(agent, StreamingPlugin)

      # Send a signal that reads conversation_id
      subscribe_to_agent_broadcasts("state-conv-id")

      signal = Jido.Signal.new!("ai.request.started", %{})
      StreamingPlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:state-conv-id",
        event: "agent_signal",
        payload: %{type: "state.change", state: :thinking}
      }
    end

    test "falls back to extracting conversation_id from agent ID" do
      uuid = "12345678-1234-1234-1234-123456789abc"
      agent = ConversationAgent.new(id: "conv:#{uuid}")

      # Set state WITHOUT conversation_id to test fallback
      agent =
        set_state!(agent, %{
          user_id: "user-fallback",
          mode: :chat
        })

      context = build_plugin_context(agent, StreamingPlugin)

      expected_topic = "agents:#{uuid}"
      subscribe_to_agent_broadcasts(uuid)

      signal = Jido.Signal.new!("ai.request.started", %{})
      StreamingPlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: ^expected_topic,
        event: "agent_signal",
        payload: %{type: "state.change", state: :thinking}
      }
    end
  end
end
