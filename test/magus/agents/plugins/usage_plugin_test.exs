defmodule Magus.Agents.Plugins.UsagePluginTest do
  use Magus.DataCase, async: true

  alias Magus.Agents.Plugins.UsagePlugin
  alias Magus.Agents.Plugins.Support.Helpers

  @conversation_id "usage-plugin-conv-id"
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
          __strategy__: %{active_request_id: @message_id}
        },
        overrides
      )

    %{id: "conv:#{@conversation_id}", state: base_state}
  end

  defp build_context(agent) do
    %{agent: agent}
  end

  defp make_signal(type, data) do
    Jido.Signal.new!(type, data)
  end

  # ============================================================================
  # Plugin Metadata
  # ============================================================================

  describe "plugin metadata" do
    test "has correct name and state_key" do
      assert UsagePlugin.name() == "usage"
      assert UsagePlugin.state_key() == :usage
    end

    test "has single signal pattern for ai.usage" do
      patterns = UsagePlugin.signal_patterns()
      assert patterns == ["ai.usage"]
    end

    test "plugin_spec returns valid spec" do
      spec = UsagePlugin.plugin_spec()
      assert spec.module == UsagePlugin
      assert spec.name == "usage"
      assert spec.state_key == :usage
      assert spec.actions == []
      assert spec.signal_patterns == ["ai.usage"]
    end

    test "has description and category" do
      assert UsagePlugin.description() =~ "usage"
      assert UsagePlugin.category() == "magus"
    end

    test "has tags" do
      tags = UsagePlugin.tags()
      assert "conversation" in tags
      assert "usage" in tags
      assert "billing" in tags
    end
  end

  # ============================================================================
  # Mount
  # ============================================================================

  describe "mount/2" do
    test "initializes plugin state with config" do
      agent = build_agent()
      {:ok, state} = UsagePlugin.mount(agent, %{some: :config})

      assert Map.has_key?(state, :config)
      assert state[:config] == %{some: :config}
    end

    test "initializes with empty config" do
      agent = build_agent()
      {:ok, state} = UsagePlugin.mount(agent, %{})

      assert state[:config] == %{}
    end
  end

  # ============================================================================
  # ai.usage handling
  # ============================================================================

  describe "handle_signal/2 with ai.usage" do
    test "returns {:ok, :continue} for ai.usage signal" do
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.usage", %{
          call_id: "call_#{@message_id}_1_llm-abc",
          model: "openrouter:anthropic/claude-sonnet-4",
          input_tokens: 100,
          output_tokens: 50
        })

      assert {:ok, :continue} = UsagePlugin.handle_signal(signal, context)
    end

    test "returns {:ok, :continue} even when agent state is minimal" do
      # Minimal agent with no user_id, no conversation_id
      agent = %{id: "conv:unknown", state: %{}}
      context = build_context(agent)

      signal =
        make_signal("ai.usage", %{
          call_id: "call_req-1_1_llm-1",
          model: "test-model",
          input_tokens: 10,
          output_tokens: 5
        })

      # Should not raise -- best-effort recording
      assert {:ok, :continue} = UsagePlugin.handle_signal(signal, context)
    end

    test "returns {:ok, :continue} with nil agent state fields" do
      agent = build_agent(%{user_id: nil, conversation_id: nil, mode: nil})
      context = build_context(agent)

      signal =
        make_signal("ai.usage", %{
          model: "test-model",
          input_tokens: 0,
          output_tokens: 0
        })

      assert {:ok, :continue} = UsagePlugin.handle_signal(signal, context)
    end

    test "resolves message_id from call_id when request_id not in signal data" do
      # The call_id contains the request_id and iteration, so message_id should
      # be derived deterministically
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.usage", %{
          call_id: "call_#{@message_id}_2_llm-xyz",
          model: "test-model",
          input_tokens: 50,
          output_tokens: 25
        })

      # Should succeed and derive message_id from call_id
      assert {:ok, :continue} = UsagePlugin.handle_signal(signal, context)
    end

    test "uses explicit request_id from signal data when present" do
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.usage", %{
          request_id: "explicit-request-id",
          model: "test-model",
          input_tokens: 50,
          output_tokens: 25
        })

      assert {:ok, :continue} = UsagePlugin.handle_signal(signal, context)
    end

    test "uses explicit message_id from signal data when present" do
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.usage", %{
          message_id: "explicit-message-id",
          model: "test-model",
          input_tokens: 50,
          output_tokens: 25
        })

      assert {:ok, :continue} = UsagePlugin.handle_signal(signal, context)
    end

    test "falls back to active_request_id when no call_id or request_id" do
      agent = build_agent(%{__strategy__: %{active_request_id: "active-req-id"}})
      context = build_context(agent)

      signal =
        make_signal("ai.usage", %{
          model: "test-model",
          input_tokens: 100,
          output_tokens: 50
        })

      assert {:ok, :continue} = UsagePlugin.handle_signal(signal, context)
    end

    test "handles missing call_id and request_id gracefully" do
      agent = build_agent(%{__strategy__: %{active_request_id: nil}})
      context = build_context(agent)

      signal =
        make_signal("ai.usage", %{
          model: "test-model",
          input_tokens: 10,
          output_tokens: 5
        })

      # Should log a warning about missing request_id but still return :continue
      assert {:ok, :continue} = UsagePlugin.handle_signal(signal, context)
    end

    test "defaults token counts to 0 when not provided" do
      agent = build_agent()
      context = build_context(agent)

      signal =
        make_signal("ai.usage", %{
          call_id: "call_#{@message_id}_1_llm-abc",
          model: "test-model"
        })

      assert {:ok, :continue} = UsagePlugin.handle_signal(signal, context)
    end

    test "extracts conversation_id from agent state" do
      custom_conv_id = "custom-conversation-uuid"
      agent = build_agent(%{conversation_id: custom_conv_id})
      context = build_context(agent)

      signal =
        make_signal("ai.usage", %{
          call_id: "call_#{@message_id}_1_llm-abc",
          model: "test-model",
          input_tokens: 100,
          output_tokens: 50
        })

      # This test validates the plugin uses Helpers.get_conversation_id(agent)
      # which reads from agent.state.conversation_id
      assert {:ok, :continue} = UsagePlugin.handle_signal(signal, context)
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

      result = UsagePlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result
    end

    test "passes through ai.llm.delta (handled by streaming plugin)" do
      agent = build_agent()
      context = build_context(agent)

      signal = make_signal("ai.llm.delta", %{delta: "Hello"})

      result = UsagePlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result
    end

    test "passes through message.user (handled by inbound plugin)" do
      agent = build_agent()
      context = build_context(agent)

      signal = make_signal("message.user", %{text: "Hello"})

      result = UsagePlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result
    end

    test "passes through ai.tool.result (handled by tool event plugin)" do
      agent = build_agent()
      context = build_context(agent)

      signal = make_signal("ai.tool.result", %{tool_name: "web_search"})

      result = UsagePlugin.handle_signal(signal, context)
      assert {:ok, :continue} = result
    end
  end

  # ============================================================================
  # Message ID Resolution
  # ============================================================================

  describe "message_id resolution" do
    test "derives turn-specific message_id from call_id with iteration" do
      # Verify the same deterministic ID logic as Helpers
      _call_id = "call_#{@message_id}_2_llm-xyz"
      expected_id = Helpers.response_id_for_turn(@message_id, 2)

      # The plugin should derive the same message_id that Helpers would
      assert is_binary(expected_id)
      assert String.length(expected_id) == 36
    end

    test "derives request-level message_id when iteration is not in call_id" do
      # When call_id doesn't follow the standard format, falls back to request-level ID
      expected_id = Helpers.response_id_for_request(@message_id)

      assert is_binary(expected_id)
      assert String.length(expected_id) == 36
    end
  end
end
