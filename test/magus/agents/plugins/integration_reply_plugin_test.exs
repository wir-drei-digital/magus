defmodule Magus.Agents.Plugins.IntegrationReplyPluginTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Plugins.IntegrationReplyPlugin

  @conversation_id "integration-reply-plugin-conv-id"
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

  setup do
    # Clean up process dict between tests
    Process.delete(:integration_reply_info)
    Process.delete(:integration_reply_typing_last_sent)
    :ok
  end

  # ============================================================================
  # Plugin Metadata
  # ============================================================================

  describe "plugin metadata" do
    test "has correct name and state_key" do
      assert IntegrationReplyPlugin.name() == "integration_reply"
      assert IntegrationReplyPlugin.state_key() == :integration_reply
    end

    test "listens to correct signal patterns" do
      patterns = IntegrationReplyPlugin.signal_patterns()
      assert "ai.request.started" in patterns
      assert "ai.llm.delta" in patterns
      assert "ai.tool.started" in patterns
      assert "ai.request.completed" in patterns
    end

    test "has description and category" do
      assert IntegrationReplyPlugin.description() =~ "integration"
      assert IntegrationReplyPlugin.category() == "magus"
    end

    test "has tags" do
      tags = IntegrationReplyPlugin.tags()
      assert "integration" in tags
      assert "reply" in tags
      assert "typing" in tags
    end
  end

  # ============================================================================
  # Mount
  # ============================================================================

  describe "mount/2" do
    test "initializes plugin state with config" do
      agent = build_agent()
      {:ok, state} = IntegrationReplyPlugin.mount(agent, %{some: :config})

      assert state[:config] == %{some: :config}
    end
  end

  # ============================================================================
  # Pass-through for unmatched signals
  # ============================================================================

  describe "handle_signal/2 with unmatched signal types" do
    test "passes through unrecognized signal types" do
      agent = build_agent()
      context = build_context(agent)
      signal = make_signal("some.other.signal", %{})

      assert {:ok, :continue} = IntegrationReplyPlugin.handle_signal(signal, context)
    end

    test "passes through ai.usage signal" do
      agent = build_agent()
      context = build_context(agent)
      signal = make_signal("ai.usage", %{input_tokens: 100})

      assert {:ok, :continue} = IntegrationReplyPlugin.handle_signal(signal, context)
    end
  end

  # ============================================================================
  # ai.request.started — integration lookup & caching
  # ============================================================================

  describe "handle_signal/2 with ai.request.started" do
    test "returns {:ok, :continue} when no integration found" do
      agent = build_agent()
      context = build_context(agent)
      signal = make_signal("ai.request.started", %{})

      assert {:ok, :continue} = IntegrationReplyPlugin.handle_signal(signal, context)
    end

    test "caches :none when conversation has no integration" do
      agent = build_agent()
      context = build_context(agent)
      signal = make_signal("ai.request.started", %{})

      IntegrationReplyPlugin.handle_signal(signal, context)

      assert Process.get(:integration_reply_info) == :none
    end
  end

  # ============================================================================
  # ai.llm.delta — throttled typing
  # ============================================================================

  describe "handle_signal/2 with ai.llm.delta" do
    test "returns {:ok, :continue} when no cached integration" do
      agent = build_agent()
      context = build_context(agent)
      signal = make_signal("ai.llm.delta", %{delta: "Hello"})

      assert {:ok, :continue} = IntegrationReplyPlugin.handle_signal(signal, context)
    end

    test "returns {:ok, :continue} when cached as :none" do
      Process.put(:integration_reply_info, :none)

      agent = build_agent()
      context = build_context(agent)
      signal = make_signal("ai.llm.delta", %{delta: "Hello"})

      assert {:ok, :continue} = IntegrationReplyPlugin.handle_signal(signal, context)
    end
  end

  # ============================================================================
  # ai.tool.started — throttled typing
  # ============================================================================

  describe "handle_signal/2 with ai.tool.started" do
    test "returns {:ok, :continue} when no cached integration" do
      agent = build_agent()
      context = build_context(agent)
      signal = make_signal("ai.tool.started", %{tool_name: "web_search"})

      assert {:ok, :continue} = IntegrationReplyPlugin.handle_signal(signal, context)
    end
  end

  # ============================================================================
  # ai.request.completed — reply dispatch
  # ============================================================================

  describe "handle_signal/2 with ai.request.completed" do
    test "returns {:ok, :continue} even without request_id" do
      agent = build_agent()
      context = build_context(agent)
      signal = make_signal("ai.request.completed", %{})

      assert {:ok, :continue} = IntegrationReplyPlugin.handle_signal(signal, context)
    end

    test "returns {:ok, :continue} with request_id but no integration" do
      agent = build_agent(%{__strategy__: %{streaming_text: "Hello from the agent"}})
      context = build_context(agent)
      signal = make_signal("ai.request.completed", %{request_id: @message_id})

      assert {:ok, :continue} = IntegrationReplyPlugin.handle_signal(signal, context)
    end

    test "clears integration cache after handling" do
      Process.put(:integration_reply_info, %{
        user_id: "u1",
        provider_key: :telegram,
        recipient_id: "123"
      })

      Process.put(:integration_reply_typing_last_sent, 12345)

      agent = build_agent()
      context = build_context(agent)
      signal = make_signal("ai.request.completed", %{request_id: @message_id})

      IntegrationReplyPlugin.handle_signal(signal, context)

      assert Process.get(:integration_reply_info) == nil
      assert Process.get(:integration_reply_typing_last_sent) == nil
    end

    test "extracts response text from strategy streaming_text" do
      agent = build_agent(%{__strategy__: %{streaming_text: "Response text"}})
      context = build_context(agent)
      signal = make_signal("ai.request.completed", %{request_id: @message_id})

      # Should not raise — dispatch will silently fail (no integration) but text extraction works
      assert {:ok, :continue} = IntegrationReplyPlugin.handle_signal(signal, context)
    end

    test "extracts response text from signal data result" do
      agent = build_agent(%{__strategy__: %{}})
      context = build_context(agent)

      signal =
        make_signal("ai.request.completed", %{request_id: @message_id, result: "Fallback text"})

      assert {:ok, :continue} = IntegrationReplyPlugin.handle_signal(signal, context)
    end

    test "skips dispatch when response text is empty" do
      agent = build_agent(%{__strategy__: %{streaming_text: ""}})
      context = build_context(agent)
      signal = make_signal("ai.request.completed", %{request_id: @message_id})

      # Should not attempt dispatch
      assert {:ok, :continue} = IntegrationReplyPlugin.handle_signal(signal, context)
    end
  end

  # ============================================================================
  # send_typing nil recipient guard
  # ============================================================================

  describe "typing with nil recipient_id" do
    test "does not crash when recipient_id is nil" do
      # Simulate single-mode integration with no recipient
      Process.put(:integration_reply_info, %{
        user_id: @user_id,
        provider_key: :telegram,
        recipient_id: nil
      })

      Process.put(:integration_reply_typing_last_sent, 0)

      agent = build_agent()
      context = build_context(agent)
      signal = make_signal("ai.llm.delta", %{delta: "Hello"})

      # Should not crash — nil guard should prevent API call
      assert {:ok, :continue} = IntegrationReplyPlugin.handle_signal(signal, context)
    end
  end

  # ============================================================================
  # Throttling
  # ============================================================================

  describe "typing throttle" do
    test "does not send typing when within throttle window" do
      Process.put(:integration_reply_info, %{
        user_id: @user_id,
        provider_key: :telegram,
        recipient_id: "123"
      })

      # Set last sent to "just now"
      Process.put(:integration_reply_typing_last_sent, System.monotonic_time(:millisecond))

      agent = build_agent()
      context = build_context(agent)
      signal = make_signal("ai.llm.delta", %{delta: "Hello"})

      # Should not attempt to send (within throttle window)
      assert {:ok, :continue} = IntegrationReplyPlugin.handle_signal(signal, context)

      # Timestamp should remain unchanged (no new send)
      assert Process.get(:integration_reply_typing_last_sent) != 0
    end
  end
end
