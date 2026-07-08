defmodule Magus.Agents.Actions.MemoryActionsTest do
  @moduledoc """
  Tests for memory actions (BuildMemoryContext, ExtractTurnMemories).
  """
  use Magus.ResourceCase, async: true

  import Mox

  alias Magus.Agents.Actions.BuildMemoryContext
  alias Magus.Memory, as: MemoryDomain
  alias Magus.Test.Mocks.LLMMock
  alias Magus.Test.MockResponses

  setup :verify_on_exit!

  describe "BuildMemoryContext action" do
    test "builds empty context when no memories exist" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      {:ok, context} =
        BuildMemoryContext.build(%{
          user_id: user.id,
          conversation_id: conv.id,
          query_text: "test query",
          global_enabled: true
        })

      assert context.important == []
      assert context.semantic == []
      assert context.global_enabled == true
    end

    test "includes recently updated memories in context" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      # Create a memory — it will be a key memory by virtue of being most recently updated
      {:ok, _memory} =
        MemoryDomain.create_memory(
          conv.id,
          user.id,
          "Important Memory",
          %{summary: "Important context", content: %{"key" => "value"}},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      {:ok, context} =
        BuildMemoryContext.build(%{
          user_id: user.id,
          conversation_id: conv.id,
          query_text: "anything",
          global_enabled: true
        })

      assert length(context.important) == 1
      assert hd(context.important).name == "Important Memory"
    end

    test "includes memories in context when no semantic matches" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      # Create a memory (without embedding, so no semantic match)
      {:ok, _memory} =
        MemoryDomain.create_memory(
          conv.id,
          user.id,
          "Some Memory",
          %{summary: "Some context"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      {:ok, context} =
        BuildMemoryContext.build(%{
          user_id: user.id,
          conversation_id: conv.id,
          query_text: "",
          global_enabled: true
        })

      # Memory appears in important (top by recency)
      # since it's the only memory for this conversation
      all_memories = context.important ++ context.semantic
      assert length(all_memories) == 1
      assert hd(all_memories).name == "Some Memory"
    end

    test "respects global_enabled setting" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      # Create a user-scope memory
      {:ok, _global} =
        MemoryDomain.create_user_memory(
          user.id,
          nil,
          "Global Pref",
          %{summary: "User preference"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      {:ok, context} =
        BuildMemoryContext.build(%{
          user_id: user.id,
          conversation_id: conv.id,
          query_text: "",
          global_enabled: false
        })

      # User-scope memory should not be included when global_enabled is false
      all_memories = context.important ++ context.semantic
      refute Enum.any?(all_memories, &(&1.name == "Global Pref"))
      assert context.global_enabled == false
    end

    test "formats context as string" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      {:ok, _memory} =
        MemoryDomain.create_memory(
          conv.id,
          user.id,
          "Test Memory",
          %{summary: "Test summary", content: %{"data" => 123}},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      {:ok, context} =
        BuildMemoryContext.build(%{
          user_id: user.id,
          conversation_id: conv.id,
          query_text: "",
          global_enabled: true
        })

      formatted = context.formatted
      assert String.contains?(formatted, "## Your Memory")
      assert String.contains?(formatted, "Test Memory")
      assert String.contains?(formatted, "Test summary")
    end

    test "important memories are not duplicated in semantic" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      # Create a memory — it's a key memory by virtue of being most recently updated
      {:ok, _memory} =
        MemoryDomain.create_memory(
          conv.id,
          user.id,
          "Important Memory",
          %{summary: "Important"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      {:ok, context} =
        BuildMemoryContext.build(%{
          user_id: user.id,
          conversation_id: conv.id,
          query_text: "",
          global_enabled: true
        })

      # Memory should only appear in important, not in semantic
      assert length(context.important) == 1
      assert context.semantic == []
    end
  end

  describe "ExtractTurnMemories action" do
    alias Magus.Agents.Actions.ExtractTurnMemories

    test "returns error for missing user_id" do
      assert {:error, "user_id is required"} =
               ExtractTurnMemories.run(
                 %{
                   conversation_id: Ash.UUIDv7.generate(),
                   user_message: "test message",
                   agent_response: "test response"
                 },
                 %{}
               )
    end

    test "returns error for missing conversation_id" do
      assert {:error, "conversation_id is required"} =
               ExtractTurnMemories.run(
                 %{
                   user_id: Ash.UUIDv7.generate(),
                   user_message: "test message",
                   agent_response: "test response"
                 },
                 %{}
               )
    end

    test "returns result when messages too short" do
      {:ok, result} =
        ExtractTurnMemories.run(
          %{
            user_id: Ash.UUIDv7.generate(),
            conversation_id: Ash.UUIDv7.generate(),
            user_message: "short",
            agent_response: "msg"
          },
          %{}
        )

      assert result.extractions_applied == 0
      assert result.extractions_skipped == 0
    end

    test "extraction never creates user-scope rows even if the LLM emits scope=user" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      # Mock the LLM to return an extraction carrying a rogue "scope" => "user"
      # key. The action no longer reads "scope" at all (memory-v2: per-turn
      # extraction writes local only; a nightly distiller owns user-level
      # durability), so this must land as a local memory regardless.
      expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        MockResponses.generate_object_response(%{
          "extractions" => [
            %{
              "name" => "rogue",
              "summary" => "s",
              "content" => %{},
              "scope" => "user",
              "reason" => "r"
            }
          ]
        })
      end)

      user_message =
        String.duplicate("I always want this remembered across every conversation I start. ", 2)

      agent_response =
        String.duplicate("Understood, I will keep that in mind going forward for you. ", 2)

      assert {:ok, %{extractions_applied: 1, extractions_skipped: 0}} =
               ExtractTurnMemories.run(
                 %{
                   user_id: user.id,
                   conversation_id: conv.id,
                   user_message: user_message,
                   agent_response: agent_response
                 },
                 %{}
               )

      # A local memory with that name exists for the conversation.
      {:ok, local_memories} =
        MemoryDomain.list_memories_for_conversation(conv.id, actor: user)

      assert Enum.any?(local_memories, &(&1.name == "rogue" and &1.scope == :local))

      # It does not appear in any user-scope bucket.
      {:ok, user_memories} = MemoryDomain.list_user_memories(nil, actor: user)
      refute Enum.any?(user_memories, &(&1.name == "rogue"))

      # No Memory row with scope == :user and that name exists at all.
      require Ash.Query

      {:ok, rogue_user_rows} =
        Magus.Memory.Memory
        |> Ash.Query.filter(name == "rogue" and scope == :user)
        |> Ash.read(authorize?: false)

      assert rogue_user_rows == []
    end
  end
end
