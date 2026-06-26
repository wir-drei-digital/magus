defmodule Magus.Agents.Plugins.ContextPluginTest do
  # async: false because tests subscribe to PubSub via MagusWeb.Endpoint.subscribe
  # to assert context.updated broadcasts; shared subscriptions require non-async.
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.Plugins.ContextPlugin
  alias Magus.Agents.Support.AiAgent

  # ============================================================================
  # Test Helpers
  # ============================================================================

  # Helpers.get_conversation_id/1 reads agent.state[:conversation_id] first,
  # falling back to parsing "conv:<uuid>" from agent.id. We carry the real
  # conversation UUID in state so snapshot upserts satisfy the FK.
  defp build_agent(conv_id, user_id) do
    %{
      id: "conv:#{conv_id}",
      state: %{
        conversation_id: to_string(conv_id),
        user_id: to_string(user_id),
        mode: :chat
      }
    }
  end

  defp make_signal(type, data) do
    Jido.Signal.new!(type, data)
  end

  setup do
    user = generate(user())
    conv = generate(conversation(actor: user))
    agent = build_agent(conv.id, user.id)
    %{conv: conv, agent: agent, user: user}
  end

  # ============================================================================
  # Plugin Metadata
  # ============================================================================

  describe "plugin metadata" do
    test "has correct name and state_key" do
      assert ContextPlugin.name() == "context"
      assert ContextPlugin.state_key() == :context
    end

    test "has signal patterns for ai.context and ai.usage" do
      patterns = ContextPlugin.signal_patterns()
      assert "ai.context" in patterns
      assert "ai.usage" in patterns
    end
  end

  # ============================================================================
  # mount/2
  # ============================================================================

  describe "mount/2" do
    test "initializes plugin state with config", %{agent: agent} do
      {:ok, state} = ContextPlugin.mount(agent, %{some: :config})
      assert state[:config] == %{some: :config}
    end
  end

  # ============================================================================
  # ai.context
  # ============================================================================

  test "ai.context upserts a snapshot and broadcasts context.updated", %{
    conv: conv,
    agent: agent
  } do
    MagusWeb.Endpoint.subscribe("agents:#{conv.id}")

    signal =
      make_signal("ai.context", %{
        breakdown: %{categories: [], total_tokens: 42},
        model_key: "openrouter:test",
        max_context: 200_000
      })

    assert {:ok, :continue} = ContextPlugin.handle_signal(signal, %{agent: agent})

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "agent_signal",
                     payload: %{type: "context.updated"}
                   },
                   500

    {:ok, cw} = Magus.Chat.get_context_window(conv.id, actor: %AiAgent{})
    assert cw.last_total_tokens == 42
    assert cw.last_model_key == "openrouter:test"
    assert cw.last_max_context == 200_000
  end

  # ============================================================================
  # ai.usage
  # ============================================================================

  test "ai.usage patches actual/cached tokens", %{conv: conv, agent: agent} do
    {:ok, _} = Magus.Chat.get_or_create_context_window(conv.id, actor: %AiAgent{})

    # Real shape: cached arrives in metadata (forwarded by ReactStrategy), input
    # at top level.
    signal = make_signal("ai.usage", %{input_tokens: 999, metadata: %{cached_tokens: 100}})

    assert {:ok, :continue} = ContextPlugin.handle_signal(signal, %{agent: agent})

    {:ok, cw} = Magus.Chat.get_context_window(conv.id, actor: %AiAgent{})
    assert cw.last_actual_input_tokens == 999
    assert cw.last_cached_tokens == 100
  end

  test "ai.usage with no existing context window is a no-op", %{agent: agent} do
    signal = make_signal("ai.usage", %{input_tokens: 999, cached_tokens: 100})
    assert {:ok, :continue} = ContextPlugin.handle_signal(signal, %{agent: agent})
  end

  # ============================================================================
  # Auto-compact valve
  # ============================================================================

  describe "auto-compact valve" do
    # fill = 90_000 / 100_000 = 0.90 >= the 0.85 auto_compact_fraction default.
    defp over_threshold_signal do
      make_signal("ai.context", %{
        breakdown: %{categories: [], total_tokens: 90_000, max_context: 100_000},
        model_key: "openrouter:test",
        max_context: 100_000
      })
    end

    defp under_threshold_signal do
      make_signal("ai.context", %{
        breakdown: %{categories: [], total_tokens: 10_000, max_context: 100_000},
        model_key: "openrouter:test",
        max_context: 100_000
      })
    end

    defp compaction_status(conv_id) do
      {:ok, cw} = Magus.Chat.get_context_window(conv_id, actor: %AiAgent{})
      cw.compaction_status
    end

    # Force the per-conversation strategy override as the owner (set_strategy is
    # owner-gated).
    defp set_strategy!(conv_id, user, strategy) do
      {:ok, _} = Magus.Chat.get_or_create_context_window(conv_id, actor: %AiAgent{})
      {:ok, cw} = Magus.Chat.get_context_window(conv_id, actor: %AiAgent{})
      {:ok, _} = Magus.Chat.set_context_strategy(cw, %{strategy: strategy}, actor: user)
    end

    test "compact strategy over threshold while idle requests compaction", %{
      conv: conv,
      agent: agent,
      user: user
    } do
      set_strategy!(conv.id, user, :compact)

      assert {:ok, :continue} =
               ContextPlugin.handle_signal(over_threshold_signal(), %{agent: agent})

      assert compaction_status(conv.id) == :pending
    end

    test "rolling strategy over threshold stays idle", %{conv: conv, agent: agent} do
      # :rolling is the config default; no override needed.
      assert {:ok, :continue} =
               ContextPlugin.handle_signal(over_threshold_signal(), %{agent: agent})

      assert compaction_status(conv.id) == :idle
    end

    test "compact strategy under threshold stays idle", %{
      conv: conv,
      agent: agent,
      user: user
    } do
      set_strategy!(conv.id, user, :compact)

      assert {:ok, :continue} =
               ContextPlugin.handle_signal(under_threshold_signal(), %{agent: agent})

      assert compaction_status(conv.id) == :idle
    end

    test "auto_compact_enabled=false is a no-op", %{conv: conv, agent: agent, user: user} do
      set_strategy!(conv.id, user, :compact)

      original = Application.get_env(:magus, Magus.Chat.ContextWindow)

      Application.put_env(
        :magus,
        Magus.Chat.ContextWindow,
        Keyword.put(original, :auto_compact_enabled, false)
      )

      on_exit(fn -> Application.put_env(:magus, Magus.Chat.ContextWindow, original) end)

      assert {:ok, :continue} =
               ContextPlugin.handle_signal(over_threshold_signal(), %{agent: agent})

      assert compaction_status(conv.id) == :idle
    end

    test "compact strategy over threshold while already pending does not re-request", %{
      conv: conv,
      agent: agent,
      user: user
    } do
      set_strategy!(conv.id, user, :compact)

      assert {:ok, :continue} =
               ContextPlugin.handle_signal(over_threshold_signal(), %{agent: agent})

      assert compaction_status(conv.id) == :pending

      # Second over-threshold signal must not raise or change the status away
      # from :pending (the :idle guard blocks re-enqueue).
      assert {:ok, :continue} =
               ContextPlugin.handle_signal(over_threshold_signal(), %{agent: agent})

      assert compaction_status(conv.id) == :pending
    end
  end

  # ============================================================================
  # Pass-through
  # ============================================================================

  test "non-context/usage signals are ignored", %{agent: agent} do
    signal = make_signal("text.chunk", %{delta: "Hello"})
    assert {:ok, :continue} = ContextPlugin.handle_signal(signal, %{agent: agent})
  end
end
