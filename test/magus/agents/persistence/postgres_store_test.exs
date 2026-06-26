defmodule Magus.Agents.Persistence.PostgresStoreTest do
  use Magus.DataCase, async: true

  alias Magus.Agents.Persistence.PostgresStore
  alias Magus.Agents.ConversationAgent

  @test_module ConversationAgent

  # Helper to set agent state, unwrapping the {:ok, agent} tuple
  defp set_state!(agent, state) do
    {:ok, updated} = Jido.Agent.set(agent, state)
    updated
  end

  describe "get_checkpoint/2" do
    test "returns :not_found when no state exists" do
      key = {@test_module, "nonexistent-agent-id"}

      assert :not_found = PostgresStore.get_checkpoint(key, [])
    end

    test "returns {:ok, data} when state exists" do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"
      key = {@test_module, agent_id}

      # Store a canonical checkpoint
      checkpoint = %{
        version: 1,
        agent_module: @test_module,
        id: agent_id,
        state: %{
          conversation_id: "conv-123",
          user_id: "user-456",
          mode: :chat
        },
        thread: nil
      }

      :ok = PostgresStore.put_checkpoint(key, checkpoint, [])

      # Now retrieve it
      assert {:ok, data} = PostgresStore.get_checkpoint(key, [])

      # Top-level keys are atomized, nested values may remain strings
      assert data[:id] == agent_id
      assert data[:version] == 1
      assert data[:thread] == nil
      assert data[:state]["conversation_id"] == "conv-123"
      assert data[:state]["user_id"] == "user-456"
      assert data[:state]["mode"] == "chat"
    end

    test "handles complex nested data" do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"
      key = {@test_module, agent_id}

      checkpoint = %{
        version: 1,
        agent_module: @test_module,
        id: agent_id,
        state: %{
          conversation_id: "conv-123",
          user_id: "user-456",
          model_keys: %{
            chat: "openrouter:gpt-4",
            image: "openrouter:dall-e",
            video: "aimlapi:sora"
          },
          mode: :reasoning
        },
        thread: nil
      }

      :ok = PostgresStore.put_checkpoint(key, checkpoint, [])

      {:ok, data} = PostgresStore.get_checkpoint(key, [])

      # Nested maps have string keys after JSON round-trip
      assert data[:state]["model_keys"] == %{
               "chat" => "openrouter:gpt-4",
               "image" => "openrouter:dall-e",
               "video" => "aimlapi:sora"
             }
    end
  end

  describe "put_checkpoint/3" do
    test "stores new agent state" do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"
      key = {@test_module, agent_id}

      checkpoint = %{
        version: 1,
        id: agent_id,
        state: %{conversation_id: "conv-new", user_id: "user-new"},
        thread: nil
      }

      assert :ok = PostgresStore.put_checkpoint(key, checkpoint, [])

      # Verify it was stored
      assert {:ok, _data} = PostgresStore.get_checkpoint(key, [])
    end

    test "upserts existing agent state" do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"
      key = {@test_module, agent_id}

      # Store initial state
      initial = %{
        version: 1,
        id: agent_id,
        state: %{conversation_id: "conv-initial", user_id: "user-initial", mode: :chat},
        thread: nil
      }

      :ok = PostgresStore.put_checkpoint(key, initial, [])

      # Update with new state
      updated = %{
        version: 1,
        id: agent_id,
        state: %{conversation_id: "conv-updated", user_id: "user-updated", mode: :reasoning},
        thread: nil
      }

      assert :ok = PostgresStore.put_checkpoint(key, updated, [])

      # Verify the update
      {:ok, data} = PostgresStore.get_checkpoint(key, [])
      assert data[:state]["conversation_id"] == "conv-updated"
      assert data[:state]["user_id"] == "user-updated"
      assert data[:state]["mode"] == "reasoning"
    end

    test "stores agent state with correct module name" do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"
      key = {@test_module, agent_id}

      checkpoint = %{version: 1, id: agent_id, state: %{}, thread: nil}
      :ok = PostgresStore.put_checkpoint(key, checkpoint, [])

      # Query directly to check module name storage
      require Ash.Query

      {:ok, record} =
        Magus.Agents.AgentState
        |> Ash.Query.filter(agent_id == ^agent_id)
        |> Ash.read_one(authorize?: false)

      assert record.agent_module == "Magus.Agents.ConversationAgent"
    end

    test "stores plain agent ID string, not inspect-ed tuple" do
      agent_id = "conv:key-format-test-#{System.unique_integer([:positive])}"
      key = {@test_module, agent_id}

      checkpoint = %{version: 1, id: agent_id, state: %{}, thread: nil}
      :ok = PostgresStore.put_checkpoint(key, checkpoint, [])

      require Ash.Query

      {:ok, record} =
        Magus.Agents.AgentState
        |> Ash.Query.filter(agent_id == ^agent_id)
        |> Ash.read_one(authorize?: false)

      # The stored agent_id should be the plain string, not an inspect-ed tuple
      assert record.agent_id == agent_id
      refute String.contains?(record.agent_id, "{")
      refute String.contains?(record.agent_id, "conversations")
    end
  end

  describe "delete_checkpoint/2" do
    test "deletes existing agent state" do
      agent_id = "test-agent-#{System.unique_integer([:positive])}"
      key = {@test_module, agent_id}

      # Store some data first
      checkpoint = %{version: 1, id: agent_id, state: %{}, thread: nil}
      :ok = PostgresStore.put_checkpoint(key, checkpoint, [])

      # Verify it exists
      assert {:ok, _} = PostgresStore.get_checkpoint(key, [])

      # Delete it
      assert :ok = PostgresStore.delete_checkpoint(key, [])

      # Verify it's gone
      assert :not_found = PostgresStore.get_checkpoint(key, [])
    end

    test "returns :ok when deleting non-existent state" do
      key = {@test_module, "nonexistent-agent-id"}

      assert :ok = PostgresStore.delete_checkpoint(key, [])
    end
  end

  describe "Jido.Persist integration" do
    test "hibernate/4 and thaw/3 round-trip" do
      agent_id = "conv:hibernate-test-#{System.unique_integer([:positive])}"

      # Create an agent
      agent = ConversationAgent.new(id: agent_id)

      agent =
        set_state!(agent, %{
          conversation_id: "hibernate-conv",
          user_id: "hibernate-user",
          model_keys: %{chat: "model-1", image: "model-2"},
          mode: :reasoning
        })

      storage_config = {PostgresStore, []}

      # Hibernate (calls checkpoint + enforce_checkpoint_invariants + put_checkpoint)
      :ok =
        Jido.Persist.hibernate(storage_config, ConversationAgent, agent_id, agent)

      # Thaw (calls get_checkpoint + restore + rehydrate_thread)
      {:ok, restored} =
        Jido.Persist.thaw(storage_config, ConversationAgent, agent_id)

      assert restored.id == agent_id
      assert restored.state.conversation_id == "hibernate-conv"
      assert restored.state.user_id == "hibernate-user"
      assert restored.state.mode == :reasoning
      assert restored.state.model_keys == %{chat: "model-1", image: "model-2"}
    end

    test "thaw/3 returns error for non-existent agent" do
      storage_config = {PostgresStore, []}

      assert {:error, :not_found} =
               Jido.Persist.thaw(
                 storage_config,
                 ConversationAgent,
                 "nonexistent-agent"
               )
    end
  end

  describe "thawed agent functionality" do
    test "thawed agent has strategy function available" do
      agent_id = "conv:strategy-test-#{System.unique_integer([:positive])}"

      agent = ConversationAgent.new(id: agent_id)

      agent =
        set_state!(agent, %{
          conversation_id: "test-conv",
          user_id: "test-user",
          mode: :chat
        })

      storage_config = {PostgresStore, []}

      # Use hibernate/4 which adds thread pointer via enforce_checkpoint_invariants
      :ok = Jido.Persist.hibernate(storage_config, ConversationAgent, agent_id, agent)

      # Thaw the agent
      {:ok, thawed} = Jido.Persist.thaw(storage_config, ConversationAgent, agent_id)

      # The thawed agent should work with ConversationAgent module functions
      assert ConversationAgent.strategy() == Magus.Agents.Strategies.ReactStrategy

      # The thawed agent should be a valid Jido.Agent struct
      assert %Jido.Agent{} = thawed
      assert thawed.name == "conversation"
    end

    test "thawed agent can have state updated" do
      agent_id = "conv:update-test-#{System.unique_integer([:positive])}"

      agent = ConversationAgent.new(id: agent_id)

      agent =
        set_state!(agent, %{
          conversation_id: "test-conv",
          user_id: "test-user",
          mode: :chat
        })

      storage_config = {PostgresStore, []}

      # Use hibernate/4 for proper checkpoint with thread pointer
      :ok = Jido.Persist.hibernate(storage_config, ConversationAgent, agent_id, agent)
      {:ok, thawed} = Jido.Persist.thaw(storage_config, ConversationAgent, agent_id)

      # Should be able to update state on thawed agent
      {:ok, updated} = Jido.Agent.set(thawed, %{mode: :reasoning})
      assert updated.state.mode == :reasoning
    end
  end

  describe "edge cases and error handling" do
    test "handles extra unexpected fields in stored data gracefully" do
      agent_id = "conv:extra-fields-#{System.unique_integer([:positive])}"
      key = {@test_module, agent_id}

      # Store data with extra fields that aren't part of normal checkpoint
      checkpoint = %{
        version: 1,
        id: agent_id,
        state: %{
          conversation_id: "conv-123",
          user_id: "user-456",
          mode: :chat,
          # Extra fields that might be from an older/newer version
          some_unknown_field: "should be ignored",
          another_field: %{nested: "data"}
        },
        thread: nil
      }

      :ok = PostgresStore.put_checkpoint(key, checkpoint, [])
      {:ok, data} = PostgresStore.get_checkpoint(key, [])

      # Should still restore successfully, ignoring unknown fields
      {:ok, agent} = ConversationAgent.restore(data, %{})
      assert agent.state.conversation_id == "conv-123"
      assert agent.state.mode == :chat
    end

    test "handles nil model_keys gracefully" do
      data = %{
        "id" => "test-agent",
        "state" => %{
          "conversation_id" => "conv-123",
          "user_id" => "user-456",
          "model_keys" => nil,
          "mode" => "chat"
        }
      }

      {:ok, agent} = ConversationAgent.restore(data, %{})
      assert agent.state.model_keys == %{}
    end

    test "handles empty model_keys map" do
      data = %{
        "id" => "test-agent",
        "state" => %{
          "conversation_id" => "conv-123",
          "user_id" => "user-456",
          "model_keys" => %{},
          "mode" => "chat"
        }
      }

      {:ok, agent} = ConversationAgent.restore(data, %{})
      assert agent.state.model_keys == %{}
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

  describe "full persistence cycle" do
    test "agent survives full hibernate/thaw cycle via store" do
      agent_id = "conv:test-conversation-#{System.unique_integer([:positive])}"

      # Create an agent and set its state
      agent = ConversationAgent.new(id: agent_id)

      agent =
        set_state!(agent, %{
          conversation_id: "test-conv-id",
          user_id: "test-user-id",
          model_keys: %{
            chat: "openrouter:claude-3",
            image: "openrouter:flux"
          },
          mode: :search
        })

      storage_config = {PostgresStore, []}

      # Hibernate (full flow: checkpoint → enforce_invariants → put_checkpoint)
      :ok = Jido.Persist.hibernate(storage_config, ConversationAgent, agent_id, agent)

      # Thaw (full flow: get_checkpoint → restore → rehydrate_thread)
      {:ok, restored_agent} = Jido.Persist.thaw(storage_config, ConversationAgent, agent_id)

      # Verify the agent was restored correctly
      assert restored_agent.id == agent_id
      assert restored_agent.state.conversation_id == "test-conv-id"
      assert restored_agent.state.user_id == "test-user-id"
      assert restored_agent.state.mode == :search

      assert restored_agent.state.model_keys == %{
               chat: "openrouter:claude-3",
               image: "openrouter:flux"
             }
    end

    test "multiple agents can be stored and retrieved independently" do
      storage_config = {PostgresStore, []}

      agents =
        for i <- 1..3 do
          agent_id = "conv:multi-test-#{i}-#{System.unique_integer([:positive])}"

          agent = ConversationAgent.new(id: agent_id)

          agent =
            set_state!(agent, %{
              conversation_id: "conv-#{i}",
              user_id: "user-#{i}",
              mode: Enum.at([:chat, :search, :reasoning], i - 1)
            })

          :ok = Jido.Persist.hibernate(storage_config, ConversationAgent, agent_id, agent)

          {agent_id, agent}
        end

      # Retrieve and verify each agent independently
      for {agent_id, original} <- agents do
        {:ok, restored} = Jido.Persist.thaw(storage_config, ConversationAgent, agent_id)

        assert restored.id == original.id
        assert restored.state.conversation_id == original.state.conversation_id
        assert restored.state.user_id == original.state.user_id
        assert restored.state.mode == original.state.mode
      end
    end
  end
end
