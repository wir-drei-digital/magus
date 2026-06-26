defmodule Magus.Agents.ConversationAgentTest do
  use Magus.DataCase, async: true

  alias Magus.Agents.ConversationAgent

  # Helper to set agent state, unwrapping the {:ok, agent} tuple
  defp set_state!(agent, state) do
    {:ok, updated} = Jido.Agent.set(agent, state)
    updated
  end

  describe "agent configuration" do
    test "uses ReactStrategy" do
      assert ConversationAgent.strategy() == Magus.Agents.Strategies.ReactStrategy
    end

    test "has strategy options configured" do
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
    end

    test "has all composable plugins registered" do
      plugins = ConversationAgent.plugins()

      assert Magus.Agents.Plugins.InboundPlugin in plugins
      assert Magus.Agents.Plugins.StreamingPlugin in plugins
      assert Magus.Agents.Plugins.PersistencePlugin in plugins
      assert Magus.Agents.Plugins.ToolEventPlugin in plugins
      assert Magus.Agents.Plugins.UsagePlugin in plugins
      assert Magus.Agents.Plugins.ContextPlugin in plugins
      assert Magus.Agents.Plugins.AgentRunCompletionPlugin in plugins
    end

    test "new/1 creates agent with default state" do
      agent = ConversationAgent.new(id: "test-123")

      assert agent.id == "test-123"
      assert agent.state.mode == :chat
      assert agent.state.model_keys == %{}
    end

    test "new/1 initializes plugin state for all plugins" do
      agent = ConversationAgent.new(id: "test-123")

      # Each plugin registers its state_key in agent state
      assert is_map(agent.state[:inbound])
      assert is_map(agent.state[:streaming])
      assert is_map(agent.state[:persistence])
      assert is_map(agent.state[:tool_events])
      assert is_map(agent.state[:usage])
      assert is_map(agent.state[:agent_run_completion])
    end
  end

  describe "checkpoint/2" do
    test "produces canonical checkpoint format with nested state" do
      agent = ConversationAgent.new(id: "test-agent-123")

      agent =
        set_state!(agent, %{
          conversation_id: "conv-123",
          user_id: "user-456",
          model_keys: %{
            chat: "openrouter:gpt-4",
            image: "openrouter:dall-e",
            video: "aimlapi:sora"
          },
          mode: :chat
        })

      {:ok, checkpoint} = ConversationAgent.checkpoint(agent, %{})

      # Canonical format fields
      assert checkpoint.version == 1
      assert checkpoint.agent_module == ConversationAgent
      assert checkpoint.id == "test-agent-123"

      # Domain state is nested under :state
      assert checkpoint.state.conversation_id == "conv-123"
      assert checkpoint.state.user_id == "user-456"
      assert checkpoint.state.mode == :chat

      # Model keys should be converted to strings for JSON serialization
      assert checkpoint.state.model_keys == %{
               "chat" => "openrouter:gpt-4",
               "image" => "openrouter:dall-e",
               "video" => "aimlapi:sora"
             }
    end

    test "handles legacy model_key by converting to model_keys" do
      agent = ConversationAgent.new(id: "test-agent-123")

      agent =
        set_state!(agent, %{
          conversation_id: "conv-123",
          user_id: "user-456",
          model_key: "openrouter:gpt-4",
          mode: :reasoning
        })

      {:ok, checkpoint} = ConversationAgent.checkpoint(agent, %{})

      # Legacy model_key should be converted to model_keys with chat key
      assert checkpoint.state.model_keys == %{"chat" => "openrouter:gpt-4"}
    end

    test "handles empty model_keys" do
      agent = ConversationAgent.new(id: "test-agent-123")

      agent =
        set_state!(agent, %{
          conversation_id: "conv-123",
          user_id: "user-456",
          mode: :search
        })

      {:ok, checkpoint} = ConversationAgent.checkpoint(agent, %{})

      assert checkpoint.state.model_keys == %{}
    end
  end

  describe "restore/2" do
    test "restores from canonical format with nested state (string keys)" do
      data = %{
        "version" => 1,
        "agent_module" => "Elixir.Magus.Agents.ConversationAgent",
        "id" => "test-agent-123",
        "state" => %{
          "conversation_id" => "conv-123",
          "user_id" => "user-456",
          "model_keys" => %{
            "chat" => "openrouter:gpt-4",
            "image" => "openrouter:dall-e"
          },
          "mode" => "chat"
        }
      }

      {:ok, agent} = ConversationAgent.restore(data, %{})

      assert agent.id == "test-agent-123"
      assert agent.state.conversation_id == "conv-123"
      assert agent.state.user_id == "user-456"
      assert agent.state.model_keys == %{chat: "openrouter:gpt-4", image: "openrouter:dall-e"}
      assert agent.state.mode == :chat
    end

    test "restores from canonical format with atom keys" do
      data = %{
        version: 1,
        agent_module: ConversationAgent,
        id: "test-agent-123",
        state: %{
          conversation_id: "conv-123",
          user_id: "user-456",
          model_keys: %{
            chat: "openrouter:gpt-4",
            video: "aimlapi:sora"
          },
          mode: :reasoning
        }
      }

      {:ok, agent} = ConversationAgent.restore(data, %{})

      assert agent.id == "test-agent-123"
      assert agent.state.conversation_id == "conv-123"
      assert agent.state.user_id == "user-456"
      assert agent.state.model_keys == %{chat: "openrouter:gpt-4", video: "aimlapi:sora"}
      assert agent.state.mode == :reasoning
    end

    test "restores from legacy flat format with string keys" do
      dump_data = %{
        "id" => "test-agent-123",
        "conversation_id" => "conv-123",
        "user_id" => "user-456",
        "model_keys" => %{
          "chat" => "openrouter:gpt-4",
          "image" => "openrouter:dall-e"
        },
        "mode" => "chat"
      }

      {:ok, agent} = ConversationAgent.restore(dump_data, %{})

      assert agent.id == "test-agent-123"
      assert agent.state.conversation_id == "conv-123"
      assert agent.state.user_id == "user-456"
      assert agent.state.model_keys == %{chat: "openrouter:gpt-4", image: "openrouter:dall-e"}
      assert agent.state.mode == :chat
    end

    test "restores from legacy flat format with atom keys" do
      dump_data = %{
        id: "test-agent-123",
        conversation_id: "conv-123",
        user_id: "user-456",
        model_keys: %{
          chat: "openrouter:gpt-4",
          video: "aimlapi:sora"
        },
        mode: :reasoning
      }

      {:ok, agent} = ConversationAgent.restore(dump_data, %{})

      assert agent.id == "test-agent-123"
      assert agent.state.conversation_id == "conv-123"
      assert agent.state.user_id == "user-456"
      assert agent.state.model_keys == %{chat: "openrouter:gpt-4", video: "aimlapi:sora"}
      assert agent.state.mode == :reasoning
    end

    test "restores from legacy flat format with legacy model_key field" do
      dump_data = %{
        "id" => "test-agent-123",
        "conversation_id" => "conv-123",
        "user_id" => "user-456",
        "model_key" => "openrouter:legacy-model",
        "mode" => "chat"
      }

      {:ok, agent} = ConversationAgent.restore(dump_data, %{})

      # Legacy model_key should be converted to model_keys with :chat key
      assert agent.state.model_keys == %{chat: "openrouter:legacy-model"}
    end

    test "normalizes string mode to atom" do
      dump_data = %{
        "id" => "test-agent-123",
        "state" => %{
          "conversation_id" => "conv-123",
          "user_id" => "user-456",
          "mode" => "image_generation"
        }
      }

      {:ok, agent} = ConversationAgent.restore(dump_data, %{})

      assert agent.state.mode == :image_generation
    end

    test "defaults to :chat mode when mode is missing" do
      dump_data = %{
        "id" => "test-agent-123",
        "state" => %{
          "conversation_id" => "conv-123",
          "user_id" => "user-456"
        }
      }

      {:ok, agent} = ConversationAgent.restore(dump_data, %{})

      assert agent.state.mode == :chat
    end

    test "defaults to :chat mode for invalid mode string" do
      dump_data = %{
        "id" => "test-agent-123",
        "state" => %{
          "conversation_id" => "conv-123",
          "user_id" => "user-456",
          "mode" => "invalid_mode_that_does_not_exist"
        }
      }

      {:ok, agent} = ConversationAgent.restore(dump_data, %{})

      assert agent.state.mode == :chat
    end

    test "returns error when id is missing" do
      dump_data = %{
        "state" => %{
          "conversation_id" => "conv-123",
          "user_id" => "user-456"
        }
      }

      assert {:error, {:missing_field, :id}} = ConversationAgent.restore(dump_data, %{})
    end

    test "returns error when id is empty string" do
      dump_data = %{
        "id" => "",
        "state" => %{
          "conversation_id" => "conv-123",
          "user_id" => "user-456"
        }
      }

      assert {:error, {:missing_field, :id}} = ConversationAgent.restore(dump_data, %{})
    end

    test "returns error when conversation_id is missing" do
      dump_data = %{
        "id" => "test-agent-123",
        "state" => %{
          "user_id" => "user-456"
        }
      }

      assert {:error, {:missing_field, :conversation_id}} =
               ConversationAgent.restore(dump_data, %{})
    end

    test "returns error when user_id is missing" do
      dump_data = %{
        "id" => "test-agent-123",
        "state" => %{
          "conversation_id" => "conv-123"
        }
      }

      assert {:error, {:missing_field, :user_id}} = ConversationAgent.restore(dump_data, %{})
    end

    test "returns error for non-map data" do
      assert {:error, {:invalid_agent_data, "not a map"}} =
               ConversationAgent.restore("not a map", %{})

      assert {:error, {:invalid_agent_data, 123}} = ConversationAgent.restore(123, %{})
      assert {:error, {:invalid_agent_data, nil}} = ConversationAgent.restore(nil, %{})
    end

    test "returns error for Jido.Agent struct (no longer supported)" do
      agent = ConversationAgent.new(id: "test-agent-123")

      assert {:error, {:invalid_agent_data, ^agent}} = ConversationAgent.restore(agent, %{})
    end
  end

  describe "checkpoint/2 and restore/2 round-trip" do
    test "agent state survives checkpoint and restore cycle via JSON" do
      # Create original agent with full state
      original = ConversationAgent.new(id: "roundtrip-test")

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

      # Checkpoint the agent
      {:ok, checkpoint} = ConversationAgent.checkpoint(original, %{})

      # Simulate JSON serialization/deserialization (what happens in DB)
      json_dump = Jason.encode!(checkpoint)
      restored_dump = Jason.decode!(json_dump)

      # Restore from the deserialized dump
      {:ok, restored} = ConversationAgent.restore(restored_dump, %{})

      # Verify the essential state is preserved
      assert restored.id == original.id
      assert restored.state.conversation_id == original.state.conversation_id
      assert restored.state.user_id == original.state.user_id
      assert restored.state.mode == original.state.mode

      # Model keys should be restored (converted back to atoms)
      assert restored.state.model_keys == %{
               chat: "openrouter:claude-3",
               image: "openrouter:flux",
               video: "aimlapi:kling"
             }
    end
  end

  describe "checkpoint/2 strategy recovery fields" do
    test "includes was_active: true when strategy status is :awaiting_llm" do
      agent = ConversationAgent.new(id: "recovery-test")

      agent =
        set_state!(agent, %{
          conversation_id: "conv-123",
          user_id: "user-456",
          __strategy__: %{status: :awaiting_llm, active_request_id: "msg-789"}
        })

      {:ok, checkpoint} = ConversationAgent.checkpoint(agent, %{})

      assert checkpoint.state.was_active == true
      assert checkpoint.state.active_message_id == "msg-789"
    end

    test "includes was_active: true when strategy status is :awaiting_tool" do
      agent = ConversationAgent.new(id: "recovery-test")

      agent =
        set_state!(agent, %{
          conversation_id: "conv-123",
          user_id: "user-456",
          __strategy__: %{status: :awaiting_tool, active_request_id: "msg-999"}
        })

      {:ok, checkpoint} = ConversationAgent.checkpoint(agent, %{})

      assert checkpoint.state.was_active == true
      assert checkpoint.state.active_message_id == "msg-999"
    end

    test "includes was_active: false when strategy status is :idle" do
      agent = ConversationAgent.new(id: "recovery-test")

      agent =
        set_state!(agent, %{
          conversation_id: "conv-123",
          user_id: "user-456",
          __strategy__: %{status: :idle}
        })

      {:ok, checkpoint} = ConversationAgent.checkpoint(agent, %{})

      assert checkpoint.state.was_active == false
    end

    test "includes was_active: false when no strategy state" do
      agent = ConversationAgent.new(id: "recovery-test")

      agent =
        set_state!(agent, %{
          conversation_id: "conv-123",
          user_id: "user-456"
        })

      {:ok, checkpoint} = ConversationAgent.checkpoint(agent, %{})

      assert checkpoint.state.was_active == false
    end
  end

  describe "restore/2 recovery metadata" do
    test "sets __recovery__ when was_active is true (string keys)" do
      data = %{
        "id" => "test-agent-123",
        "state" => %{
          "conversation_id" => "conv-123",
          "user_id" => "user-456",
          "was_active" => true,
          "active_message_id" => "msg-789"
        }
      }

      {:ok, agent} = ConversationAgent.restore(data, %{})

      assert agent.state[:__recovery__] == %{
               was_active: true,
               active_message_id: "msg-789"
             }
    end

    test "sets __recovery__ when was_active is true (atom keys)" do
      data = %{
        id: "test-agent-123",
        state: %{
          conversation_id: "conv-123",
          user_id: "user-456",
          was_active: true,
          active_message_id: "msg-789"
        }
      }

      {:ok, agent} = ConversationAgent.restore(data, %{})

      assert agent.state[:__recovery__] == %{
               was_active: true,
               active_message_id: "msg-789"
             }
    end

    test "no __recovery__ when was_active is false" do
      data = %{
        "id" => "test-agent-123",
        "state" => %{
          "conversation_id" => "conv-123",
          "user_id" => "user-456",
          "was_active" => false
        }
      }

      {:ok, agent} = ConversationAgent.restore(data, %{})

      refute Map.has_key?(agent.state, :__recovery__)
    end

    test "no __recovery__ when was_active is missing" do
      data = %{
        "id" => "test-agent-123",
        "state" => %{
          "conversation_id" => "conv-123",
          "user_id" => "user-456"
        }
      }

      {:ok, agent} = ConversationAgent.restore(data, %{})

      refute Map.has_key?(agent.state, :__recovery__)
    end

    test "recovery fields survive JSON round-trip" do
      agent = ConversationAgent.new(id: "roundtrip-recovery")

      agent =
        set_state!(agent, %{
          conversation_id: "conv-rt",
          user_id: "user-rt",
          __strategy__: %{status: :awaiting_llm, active_request_id: "msg-rt"}
        })

      {:ok, checkpoint} = ConversationAgent.checkpoint(agent, %{})

      json_dump = Jason.encode!(checkpoint)
      restored_dump = Jason.decode!(json_dump)

      {:ok, restored} = ConversationAgent.restore(restored_dump, %{})

      assert restored.state[:__recovery__] == %{
               was_active: true,
               active_message_id: "msg-rt"
             }
    end
  end

  describe "checkpoint produces JSON-serializable output" do
    test "checkpoint/2 returns a plain map that can be JSON encoded" do
      agent = ConversationAgent.new(id: "json-test-agent")

      agent =
        set_state!(agent, %{
          conversation_id: "conv-123",
          user_id: "user-456",
          model_keys: %{chat: "model-1", image: "model-2"},
          mode: :reasoning
        })

      {:ok, checkpoint} = ConversationAgent.checkpoint(agent, %{})

      # The checkpoint should be a plain map, not a struct
      assert is_map(checkpoint)
      refute is_struct(checkpoint)

      # It should be JSON encodable without errors
      assert {:ok, json} = Jason.encode(checkpoint)
      assert is_binary(json)

      # And decodable back with canonical nested format
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["id"] == "json-test-agent"
      assert decoded["version"] == 1
      assert decoded["state"]["conversation_id"] == "conv-123"
      assert decoded["state"]["user_id"] == "user-456"
    end

    test "checkpoint/2 does not include non-serializable structs" do
      agent = ConversationAgent.new(id: "struct-test-agent")

      agent =
        set_state!(agent, %{
          conversation_id: "conv-123",
          user_id: "user-456",
          mode: :chat
        })

      {:ok, checkpoint} = ConversationAgent.checkpoint(agent, %{})

      # Walk the checkpoint to ensure no unsafe structs exist (DateTime etc. are OK)
      assert no_unsafe_structs?(checkpoint),
             "checkpoint contains non-JSON-serializable structs: #{inspect(checkpoint)}"
    end
  end

  # Check for non-JSON-serializable structs (DateTime, Date, etc. are OK)
  @json_safe_structs [DateTime, NaiveDateTime, Date, Time, Decimal]

  defp no_unsafe_structs?(value) when is_struct(value) do
    value.__struct__ in @json_safe_structs
  end

  defp no_unsafe_structs?(value) when is_map(value) do
    Enum.all?(value, fn {_k, v} -> no_unsafe_structs?(v) end)
  end

  defp no_unsafe_structs?(value) when is_list(value) do
    Enum.all?(value, &no_unsafe_structs?/1)
  end

  defp no_unsafe_structs?(_), do: true
end
