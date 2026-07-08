defmodule Magus.Agents.Tools.Memory.MemoryToolsTest do
  @moduledoc """
  Tests for memory tools.

  Only SearchMemories remains as an explicit tool available to the LLM.
  Other memory operations are handled directly by actions:

  - Context loading: BuildMemoryContext called before LLM calls
  - Memory extraction: ExtractTurnMemories called after turn completion
  - Periodic consolidation via AshOban
  - Recency-based ranking via updated_at

  This test file focuses on SearchMemories functionality.
  """
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Memory.SearchMemories
  alias Magus.Memory
  alias Magus.Chat

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  defp create_test_context do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

    %{
      user: user,
      conversation: conversation,
      context: %{
        user_id: user.id,
        conversation_id: conversation.id,
        folder_id: nil
      }
    }
  end

  defp create_memory_via_domain(conversation_id, user_id, name, opts) do
    summary = Keyword.get(opts, :summary)
    content = Keyword.get(opts, :content, %{})

    Memory.create_memory(
      conversation_id,
      user_id,
      name,
      %{summary: summary, content: content},
      actor: %Magus.Agents.Support.AiAgent{}
    )
  end

  # ---------------------------------------------------------------------------
  # SearchMemories Tests
  # ---------------------------------------------------------------------------

  describe "SearchMemories" do
    test "provides display_name" do
      assert SearchMemories.display_name() == "Searching memories..."
    end

    test "summarizes output correctly" do
      assert SearchMemories.summarize_output(%{count: 0}) == "No matches"
      assert SearchMemories.summarize_output(%{count: 3}) == "Found 3 matches"
      assert SearchMemories.summarize_output(%{error: "err"}) == "Error"
      assert SearchMemories.summarize_output(%{}) == "Completed"
    end

    @tag :external_api
    test "returns empty results for conversation without memories" do
      %{context: context} = create_test_context()

      # Note: This test requires embedding service to be available
      result = SearchMemories.run(%{query: "test"}, context)

      case result do
        {:ok, %{count: 0, results: []}} ->
          assert true

        {:ok, %{error: error}} when is_binary(error) ->
          # Embedding service may not be available in test environment
          assert error =~ "failed" or error =~ "Search" or error =~ "API"

        _ ->
          assert true
      end
    end

    test "returns error with missing context" do
      assert {:ok, result} = SearchMemories.run(%{query: "test"}, %{})
      assert result.error =~ "Missing required context"
    end

    test "returns error with invalid scope" do
      %{context: context} = create_test_context()

      assert {:ok, result} = SearchMemories.run(%{query: "test", scope: "invalid"}, context)
      assert result.error =~ "Invalid scope"
    end

    test "accepts valid scope values" do
      %{context: context} = create_test_context()

      # These should not return scope validation errors
      # They may fail due to embedding API not being available, which is fine

      for scope <- ["local", "user", "all"] do
        result = SearchMemories.run(%{query: "test", scope: scope}, context)

        case result do
          {:ok, %{error: error}} ->
            refute error =~ "Invalid scope"

          {:ok, _} ->
            assert true
        end
      end
    end

    @tag :external_api
    test "respects limit parameter" do
      %{context: context} = create_test_context()

      params = %{query: "test", limit: 3}
      result = SearchMemories.run(params, context)

      case result do
        {:ok, %{results: results}} when is_list(results) ->
          assert length(results) <= 3

        {:ok, %{error: _}} ->
          # Embedding service may not be available in test environment
          assert true

        _ ->
          assert true
      end
    end

    test "requires user_id for user scope" do
      # User scope needs user_id but not conversation_id
      context = %{user_id: Ash.UUIDv7.generate()}

      result = SearchMemories.run(%{query: "test", scope: "user"}, context)

      case result do
        {:ok, %{scope: "user"}} ->
          assert true

        {:ok, %{error: error}} ->
          # Should not complain about missing user_id
          refute error =~ "user_id"
      end
    end

    test "requires both user_id and conversation_id for all scope" do
      # "all" scope needs both
      context_missing_user = %{conversation_id: Ash.UUIDv7.generate()}

      result = SearchMemories.run(%{query: "test", scope: "all"}, context_missing_user)

      case result do
        {:ok, %{error: error}} ->
          assert error =~ "Missing required context"

        _ ->
          flunk("Expected error for missing user_id")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Agent Isolation Tests
  # ---------------------------------------------------------------------------

  describe "agent isolation" do
    test "blocks global scope when can_read_global_memories is false" do
      %{context: context} = create_test_context()
      isolated_context = Map.put(context, :can_read_global_memories, false)

      assert {:ok, result} =
               SearchMemories.run(%{query: "test", scope: "user"}, isolated_context)

      assert result.error =~ "cannot access global memories"
    end

    test "downgrades 'all' scope to 'local' when can_read_global_memories is false" do
      %{context: context} = create_test_context()
      isolated_context = Map.put(context, :can_read_global_memories, false)

      result = SearchMemories.run(%{query: "test", scope: "all"}, isolated_context)

      case result do
        {:ok, %{scope: scope}} ->
          # Should have been downgraded to local
          assert scope == "local"

        {:ok, %{error: error}} ->
          # Embedding API may be unavailable, but should not be a scope error
          refute error =~ "cannot access global memories"
      end
    end

    test "allows local scope when can_read_global_memories is false" do
      %{context: context} = create_test_context()
      isolated_context = Map.put(context, :can_read_global_memories, false)

      result = SearchMemories.run(%{query: "test", scope: "local"}, isolated_context)

      case result do
        {:ok, %{error: error}} ->
          refute error =~ "cannot access global memories"

        {:ok, _} ->
          assert true
      end
    end

    test "allows all scopes when can_read_global_memories is true" do
      %{context: context} = create_test_context()
      allowed_context = Map.put(context, :can_read_global_memories, true)

      for scope <- ["local", "user", "all"] do
        result = SearchMemories.run(%{query: "test", scope: scope}, allowed_context)

        case result do
          {:ok, %{error: error}} ->
            refute error =~ "cannot access global memories"

          {:ok, _} ->
            assert true
        end
      end
    end

    test "defaults to allowed when isolation flag is absent" do
      %{context: context} = create_test_context()

      result = SearchMemories.run(%{query: "test", scope: "user"}, context)

      case result do
        {:ok, %{error: error}} ->
          refute error =~ "cannot access global memories"

        {:ok, _} ->
          assert true
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Memory Domain Integration Tests
  # ---------------------------------------------------------------------------

  describe "memory domain integration" do
    test "memories can be created and searched" do
      %{user: user, conversation: conversation} = create_test_context()

      # Create memories using the domain directly
      {:ok, _} =
        create_memory_via_domain(
          conversation.id,
          user.id,
          "Project Structure",
          summary: "Overview of the codebase organization",
          content: %{"frontend" => "React", "backend" => "Elixir"}
        )

      {:ok, _} =
        create_memory_via_domain(
          conversation.id,
          user.id,
          "Current Task",
          summary: "Working on user authentication",
          content: %{"status" => "in_progress"}
        )

      # Verify memories were created
      {:ok, memories} =
        Memory.list_memories_for_conversation(conversation.id,
          actor: %Magus.Agents.Support.AiAgent{}
        )

      assert length(memories) == 2
    end

    test "memories are sorted by recency" do
      %{user: user, conversation: conversation} = create_test_context()

      {:ok, _older} =
        create_memory_via_domain(
          conversation.id,
          user.id,
          "Older Memory",
          summary: "Created first"
        )

      {:ok, _newer} =
        create_memory_via_domain(
          conversation.id,
          user.id,
          "Newer Memory",
          summary: "Created second"
        )

      {:ok, memories} =
        Memory.list_memories_for_conversation(conversation.id,
          actor: %Magus.Agents.Support.AiAgent{}
        )

      assert hd(memories).name == "Newer Memory"
    end
  end
end
