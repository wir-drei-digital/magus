defmodule Magus.Agents.Tools.Memory.ForgetMemoryTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Memory.ForgetMemory
  alias Magus.Memory
  alias Magus.Chat

  defp create_test_context do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

    %{
      user: user,
      conversation: conversation,
      context: %{
        user_id: user.id,
        conversation_id: conversation.id
      }
    }
  end

  describe "display_name/0 and summarize_output/1" do
    test "provides display_name" do
      assert ForgetMemory.display_name() == "Forgetting memory..."
    end

    test "summarizes output correctly" do
      assert ForgetMemory.summarize_output(%{status: "forgotten", name: "foo"}) == "Forgot 'foo'"
      assert ForgetMemory.summarize_output(%{status: "not_found"}) == "Not found"
      assert ForgetMemory.summarize_output(%{error: "err"}) == "Error"
      assert ForgetMemory.summarize_output(%{}) == "Completed"
    end
  end

  describe "destroying memories" do
    test "destroys existing user memory" do
      %{user: user, context: context} = create_test_context()

      # Create a user memory
      {:ok, _} =
        Memory.create_user_memory(
          user.id,
          nil,
          "dark_mode",
          %{summary: "User prefers dark mode", content: %{"theme" => "dark"}},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      params = %{name: "dark_mode", scope: "user"}
      assert {:ok, result} = ForgetMemory.run(params, context)
      assert result.status == "forgotten"
      assert result.name == "dark_mode"
      assert result.scope == "user"

      # Verify memory is hard-deleted (lookup should fail with not found)
      actor = %Magus.Accounts.User{id: user.id}

      assert {:error, _} = Memory.get_user_memory_by_name(nil, "dark_mode", actor: actor)
    end

    test "destroys existing local memory" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      # Create a local memory
      {:ok, _} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "temp_note",
          %{summary: "Temporary note", content: %{"note" => "delete me"}},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      params = %{name: "temp_note", scope: "local"}
      assert {:ok, result} = ForgetMemory.run(params, context)
      assert result.status == "forgotten"
      assert result.name == "temp_note"
      assert result.scope == "local"

      # Verify memory is hard-deleted
      assert {:error, _} =
               Memory.get_memory_by_name(conversation.id, "temp_note",
                 actor: %Magus.Agents.Support.AiAgent{}
               )
    end

    test "ForgetMemory as ai_actor hard-deletes the memory" do
      user = generate(user())
      {:ok, conv} = Chat.create_conversation(%{}, actor: user)

      {:ok, memory} =
        Memory.create_memory(conv.id, user.id, "gone", %{content: %{}, summary: "s"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      context = %{user_id: user.id, conversation_id: conv.id}

      assert {:ok, %{status: "forgotten"}} =
               ForgetMemory.run(%{name: "gone", scope: "local"}, context)

      assert {:error, _} = Magus.Memory.get_memory(memory.id, authorize?: false)
    end

    test "hard-delete then re-create with the same name succeeds" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      {:ok, _} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "again",
          %{summary: "First version"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      params = %{name: "again", scope: "local"}
      assert {:ok, %{status: "forgotten"}} = ForgetMemory.run(params, context)

      # Unique index is no longer blocked by a soft-deleted row: the second
      # create with the same name in the same conversation must succeed.
      assert {:ok, second} =
               Memory.create_memory(
                 conversation.id,
                 user.id,
                 "again",
                 %{summary: "Second version"},
                 actor: %Magus.Agents.Support.AiAgent{}
               )

      assert second.name == "again"
    end

    test "defaults scope to local" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      {:ok, _} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "timezone",
          %{summary: "CET timezone"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      # No scope param — should default to local
      params = %{name: "timezone"}
      assert {:ok, result} = ForgetMemory.run(params, context)
      assert result.status == "forgotten"
      assert result.scope == "local"
    end
  end

  describe "not found handling" do
    test "returns not_found status when memory doesn't exist" do
      %{context: context} = create_test_context()

      params = %{name: "nonexistent", scope: "user"}
      assert {:ok, result} = ForgetMemory.run(params, context)
      assert result.status == "not_found"
      assert result.name == "nonexistent"
      assert result.hint =~ "search_memories"
    end

    test "returns not_found for local scope when memory doesn't exist" do
      %{context: context} = create_test_context()

      params = %{name: "nonexistent", scope: "local"}
      assert {:ok, result} = ForgetMemory.run(params, context)
      assert result.status == "not_found"
    end
  end

  describe "LLM string-key params" do
    test "handles string-keyed params from LLM" do
      %{user: user, context: context} = create_test_context()

      {:ok, _} =
        Memory.create_user_memory(
          user.id,
          nil,
          "theme",
          %{summary: "Dark theme"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      params = %{"name" => "theme", "scope" => "user"}
      assert {:ok, result} = ForgetMemory.run(params, context)
      assert result.status == "forgotten"
    end
  end

  describe "double-forget" do
    test "returns not_found when forgetting an already-forgotten memory" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      {:ok, _} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "temp",
          %{summary: "Temporary"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      assert {:ok, %{status: "forgotten"}} = ForgetMemory.run(%{name: "temp"}, context)
      assert {:ok, %{status: "not_found"}} = ForgetMemory.run(%{name: "temp"}, context)
    end
  end

  describe "agent isolation" do
    test "blocks global scope when can_read_global_memories is false" do
      %{context: context} = create_test_context()
      isolated_context = Map.put(context, :can_read_global_memories, false)

      params = %{name: "test_mem", scope: "user"}
      assert {:ok, result} = ForgetMemory.run(params, isolated_context)
      assert result.error =~ "cannot access global memories"
    end

    test "blocks global scope when can_write_global_memories is false" do
      %{user: user, context: context} = create_test_context()
      isolated_context = Map.put(context, :can_write_global_memories, false)

      {:ok, _} =
        Memory.create_user_memory(
          user.id,
          nil,
          "protected_mem",
          %{summary: "Protected"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      params = %{name: "protected_mem", scope: "user"}
      assert {:ok, result} = ForgetMemory.run(params, isolated_context)
      assert result.error =~ "cannot create or modify global memories"

      # Verify memory still exists
      actor = %Magus.Accounts.User{id: user.id}
      assert {:ok, _} = Memory.get_user_memory_by_name(nil, "protected_mem", actor: actor)
    end

    test "allows local scope when global access is denied" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      isolated_context =
        context
        |> Map.put(:can_read_global_memories, false)
        |> Map.put(:can_write_global_memories, false)

      {:ok, _} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "local_note",
          %{summary: "Local note"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      params = %{name: "local_note", scope: "local"}
      assert {:ok, result} = ForgetMemory.run(params, isolated_context)
      assert result.status == "forgotten"
    end

    test "allows global scope when all flags are true" do
      %{user: user, context: context} = create_test_context()

      allowed_context =
        context
        |> Map.put(:can_read_global_memories, true)
        |> Map.put(:can_write_global_memories, true)

      {:ok, _} =
        Memory.create_user_memory(
          user.id,
          nil,
          "deletable",
          %{summary: "Can be deleted"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      params = %{name: "deletable", scope: "user"}
      assert {:ok, result} = ForgetMemory.run(params, allowed_context)
      assert result.status == "forgotten"
    end

    test "defaults to allowed when isolation flags are absent" do
      %{user: user, context: context} = create_test_context()

      {:ok, _} =
        Memory.create_user_memory(
          user.id,
          nil,
          "default_access",
          %{summary: "Default access"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      params = %{name: "default_access", scope: "user"}
      assert {:ok, result} = ForgetMemory.run(params, context)
      assert result.status == "forgotten"
    end
  end

  describe "error handling" do
    test "returns error for invalid scope" do
      %{context: context} = create_test_context()

      params = %{name: "test", scope: "invalid"}
      assert {:ok, result} = ForgetMemory.run(params, context)
      assert result.error =~ "Invalid scope"
    end

    test "returns error for missing context" do
      params = %{name: "test"}
      assert {:ok, result} = ForgetMemory.run(params, %{})
      assert result.error =~ "Missing required context"
    end
  end

  describe "user-scope workspace bucketing" do
    test "user-scope forget resolves the workspace bucket from the conversation" do
      user = generate(user())
      workspace = generate(workspace(actor: user))
      {:ok, conv} = Chat.create_conversation(%{workspace_id: workspace.id}, actor: user)

      {:ok, _} =
        Memory.create_user_memory(user.id, workspace.id, "ws-fact", %{content: %{}, summary: "s"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      context = %{user_id: user.id, conversation_id: conv.id}

      assert {:ok, %{status: "forgotten"}} =
               ForgetMemory.run(%{name: "ws-fact", scope: "user"}, context)
    end
  end
end
