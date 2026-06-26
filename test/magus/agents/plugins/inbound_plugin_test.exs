defmodule Magus.Agents.Plugins.InboundPluginTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Agents.Plugins.InboundPlugin

  @conversation_id "inbound-plugin-conv-id"
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

  defp ensure_active_subscription(user) do
    plan = generate(usage_plan())

    {:ok, _subscription} =
      Magus.Usage.create_user_subscription(
        %{user_id: user.id, usage_plan_id: plan.id, status: :active},
        authorize?: false
      )

    :ok
  end

  # ============================================================================
  # Plugin Metadata
  # ============================================================================

  describe "plugin metadata" do
    test "has correct name and state_key" do
      assert InboundPlugin.name() == "inbound"
      assert InboundPlugin.state_key() == :inbound
    end

    test "has correct signal patterns" do
      patterns = InboundPlugin.signal_patterns()
      assert "message.user" in patterns
      assert "message.cancel" in patterns
      assert "message.steer" in patterns
      assert "agent.resume" in patterns
      assert "ai.request.error" in patterns
      assert length(patterns) == 5
    end

    test "plugin_spec returns valid spec" do
      spec = InboundPlugin.plugin_spec()
      assert spec.module == InboundPlugin
      assert spec.name == "inbound"
      assert spec.state_key == :inbound
      assert spec.actions == []

      assert spec.signal_patterns == [
               "message.user",
               "message.cancel",
               "message.steer",
               "agent.resume",
               "ai.request.error"
             ]
    end

    test "has description and category" do
      assert InboundPlugin.description() =~ "Inbound signal transformation"
      assert InboundPlugin.category() == "magus"
    end

    test "has tags" do
      tags = InboundPlugin.tags()
      assert "conversation" in tags
      assert "inbound" in tags
      assert "signal-transformation" in tags
    end
  end

  # ============================================================================
  # Mount
  # ============================================================================

  describe "mount/2" do
    test "initializes plugin state with config" do
      agent = build_agent()
      {:ok, state} = InboundPlugin.mount(agent, %{some: :config})

      assert Map.has_key?(state, :config)
      assert state[:config] == %{some: :config}
    end

    test "initializes with empty config" do
      agent = build_agent()
      {:ok, state} = InboundPlugin.mount(agent, %{})

      assert state[:config] == %{}
    end
  end

  # ============================================================================
  # message.user (chat mode) -> ai.react.query via Preflight
  # ============================================================================

  describe "handle_signal/2 with message.user (chat mode)" do
    test "transforms message.user to ai.react.query when user has spend budget" do
      user = generate(user())
      ensure_active_subscription(user)

      conversation = generate(conversation(actor: user))

      user_id = to_string(user.id)
      conversation_id = to_string(conversation.id)

      agent =
        build_agent(%{
          conversation_id: conversation_id,
          user_id: user_id,
          mode: :chat,
          model_keys: %{chat: "test-model"}
        })

      context = build_context(agent)

      signal =
        make_signal("message.user", %{
          message_id: @message_id,
          text: "Hello, how are you?",
          mode: :chat
        })

      result = InboundPlugin.handle_signal(signal, context)

      assert {:ok, {:continue, react_signal}} = result
      assert react_signal.type == "ai.react.query"
      assert react_signal.data[:query] == "Hello, how are you?"
      assert react_signal.data[:request_id] == @message_id
      assert react_signal.data[:model] == "test-model"
    end

    test "returns override noop when user has no spend budget" do
      user = generate(user())
      conversation = generate(conversation(actor: user))
      MagusWeb.Endpoint.subscribe("agents:#{conversation.id}")

      agent =
        build_agent(%{
          conversation_id: to_string(conversation.id),
          user_id: to_string(user.id),
          mode: :chat,
          model_keys: %{chat: "test-model"}
        })

      context = build_context(agent)

      signal =
        make_signal("message.user", %{
          message_id: @message_id,
          text: "Hello",
          mode: :chat
        })

      result = InboundPlugin.handle_signal(signal, context)

      assert {:ok, {:override, Jido.Actions.Control.Noop}} = result

      assert_receive %Phoenix.Socket.Broadcast{
        payload: %{type: "error", error_type: :limit_exceeded}
      }
    end
  end

  # ============================================================================
  # message.user (media bypass) -> image/video generation
  # ============================================================================

  describe "handle_signal/2 with message.user (media bypass)" do
    test "halts and overrides for image_generation mode" do
      subscribe_to_conversation()

      agent =
        build_agent(%{
          mode: :image_generation,
          model_keys: %{image: "test-image-model"}
        })

      context = build_context(agent)

      signal =
        make_signal("message.user", %{
          message_id: @message_id,
          text: "Generate a cat",
          mode: :image_generation
        })

      result = InboundPlugin.handle_signal(signal, context)

      # Media generation bypasses ReAct
      assert {:ok, {:override, Jido.Actions.Control.Noop}} = result
    end

    test "halts and overrides for video_generation mode" do
      subscribe_to_conversation()

      agent =
        build_agent(%{
          mode: :video_generation,
          model_keys: %{video: "test-video-model"}
        })

      context = build_context(agent)

      signal =
        make_signal("message.user", %{
          message_id: @message_id,
          text: "Generate a video",
          mode: :video_generation
        })

      result = InboundPlugin.handle_signal(signal, context)

      assert {:ok, {:override, Jido.Actions.Control.Noop}} = result
    end
  end

  # ============================================================================
  # message.cancel -> ai.react.cancel
  # ============================================================================

  describe "handle_signal/2 with message.cancel" do
    test "transforms message.cancel to ai.react.cancel signal" do
      agent = build_agent()
      context = build_context(agent)

      signal = make_signal("message.cancel", %{})

      result = InboundPlugin.handle_signal(signal, context)

      assert {:ok, {:continue, cancel_signal}} = result
      assert cancel_signal.type == "ai.react.cancel"
      assert cancel_signal.data[:reason] == :user_cancelled
    end
  end

  # ============================================================================
  # ai.request.error -> PubSub error broadcast
  # ============================================================================

  describe "handle_signal/2 with ai.request.error" do
    test "broadcasts error for request rejection (busy)" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.request.error", %{
          request_id: "req-1",
          reason: :busy,
          message: "Agent is busy"
        })

      result = InboundPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "error", error_type: :busy, error_message: "Agent is busy"}
      }
    end

    test "broadcasts state.change to idle after error" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.request.error", %{
          request_id: "req-1",
          reason: :busy,
          message: "Agent is busy"
        })

      InboundPlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "state.change", state: :idle}
      }
    end

    test "broadcasts response.complete after error" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.request.error", %{
          request_id: "req-1",
          reason: :busy,
          message: "Agent is busy"
        })

      InboundPlugin.handle_signal(signal, context)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "response.complete"}
      }
    end

    test "uses default message when none provided" do
      subscribe_to_conversation()
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.request.error", %{
          request_id: "req-1",
          reason: :rate_limited
        })

      result = InboundPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "error", error_type: :rate_limited, error_message: "Request rejected"}
      }
    end

    test "derives message_id from request_id when no active request" do
      subscribe_to_conversation()

      agent =
        build_agent(%{
          __strategy__: %{active_request_id: nil}
        })

      context = build_context(agent)

      request_id = "user-msg-uuid-123"

      signal =
        make_signal("ai.request.error", %{
          request_id: request_id,
          reason: :busy,
          message: "Agent is busy"
        })

      InboundPlugin.handle_signal(signal, context)

      expected_message_id =
        Magus.Agents.Plugins.Support.Helpers.response_id_for_request(request_id)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "agents:" <> _,
        event: "agent_signal",
        payload: %{type: "error", message_id: ^expected_message_id}
      }
    end
  end

  # ============================================================================
  # Pass-through for unmatched signals
  # ============================================================================

  describe "handle_signal/2 with unmatched signal types" do
    test "passes through unrecognized signal types" do
      agent = build_agent()
      context = build_context(agent)

      signal = make_signal("some.other.signal", %{data: "value"})

      result = InboundPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result
    end

    test "passes through ai.llm.delta (handled by other plugins)" do
      agent = build_agent()
      context = build_context(agent)

      signal = make_signal("ai.llm.delta", %{delta: "Hello"})

      result = InboundPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result
    end

    test "passes through ai.tool.result (handled by other plugins)" do
      agent = build_agent()
      context = build_context(agent)

      signal = make_signal("ai.tool.result", %{tool_name: "web_search"})

      result = InboundPlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result
    end
  end

  # ============================================================================
  # Slash command parsing
  # ============================================================================

  describe "handle_signal/2 with slash commands" do
    test "parses /reminder command and injects instruction into query" do
      user = generate(user())
      ensure_active_subscription(user)
      conversation = generate(conversation(actor: user))

      agent =
        build_agent(%{
          conversation_id: to_string(conversation.id),
          user_id: to_string(user.id),
          mode: :chat,
          model_keys: %{chat: "test-model"}
        })

      context = build_context(agent)

      signal =
        make_signal("message.user", %{
          message_id: @message_id,
          text: "/reminder pick up milk tomorrow",
          mode: :chat
        })

      result = InboundPlugin.handle_signal(signal, context)

      assert {:ok, {:continue, react_signal}} = result
      assert react_signal.type == "ai.react.query"
      assert react_signal.data[:query] =~ "<instruction>"
      assert react_signal.data[:query] =~ "pick up milk tomorrow"
    end

    test "passes through unknown slash commands unchanged" do
      user = generate(user())
      ensure_active_subscription(user)
      conversation = generate(conversation(actor: user))

      agent =
        build_agent(%{
          conversation_id: to_string(conversation.id),
          user_id: to_string(user.id),
          mode: :chat,
          model_keys: %{chat: "test-model"}
        })

      context = build_context(agent)

      signal =
        make_signal("message.user", %{
          message_id: @message_id,
          text: "/unknown do something",
          mode: :chat
        })

      result = InboundPlugin.handle_signal(signal, context)

      assert {:ok, {:continue, react_signal}} = result
      assert react_signal.data[:query] == "/unknown do something"
    end

    test "regular messages pass through without modification" do
      user = generate(user())
      ensure_active_subscription(user)
      conversation = generate(conversation(actor: user))

      agent =
        build_agent(%{
          conversation_id: to_string(conversation.id),
          user_id: to_string(user.id),
          mode: :chat,
          model_keys: %{chat: "test-model"}
        })

      context = build_context(agent)

      signal =
        make_signal("message.user", %{
          message_id: @message_id,
          text: "Hello, how are you?",
          mode: :chat
        })

      result = InboundPlugin.handle_signal(signal, context)

      assert {:ok, {:continue, react_signal}} = result
      assert react_signal.data[:query] == "Hello, how are you?"
    end
  end
end
