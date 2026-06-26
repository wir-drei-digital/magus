defmodule Magus.Agents.Tools.Memory.SetMemoryTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Memory.SetMemory
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
      assert SetMemory.display_name() == "Saving memory..."
    end

    test "summarizes output correctly" do
      assert SetMemory.summarize_output(%{status: "created", name: "foo"}) == "Created 'foo'"
      assert SetMemory.summarize_output(%{status: "updated", name: "bar"}) == "Updated 'bar'"
      assert SetMemory.summarize_output(%{error: "err"}) == "Error"
      assert SetMemory.summarize_output(%{}) == "Completed"
    end
  end

  describe "creating new memories" do
    test "creates a new user memory when none exists" do
      %{user: user, context: context} = create_test_context()

      params = %{
        name: "preferred_language",
        summary: "User prefers TypeScript",
        content: %{"language" => "TypeScript"},
        scope: "user"
      }

      assert {:ok, result} = SetMemory.run(params, context)
      assert result.status == "created"
      assert result.name == "preferred_language"
      assert result.scope == "user"

      # Verify memory exists in DB
      actor = %Magus.Accounts.User{id: user.id}
      {:ok, memory} = Memory.get_user_memory_by_name(nil, "preferred_language", actor: actor)
      assert memory.summary == "User prefers TypeScript"
      assert memory.content["language"] == "TypeScript"
    end

    test "creates a new local memory when none exists" do
      %{conversation: conversation, context: context} = create_test_context()

      params = %{
        name: "deadline",
        summary: "Project deadline is Friday",
        content: %{"day" => "Friday"},
        scope: "local"
      }

      assert {:ok, result} = SetMemory.run(params, context)
      assert result.status == "created"
      assert result.name == "deadline"
      assert result.scope == "local"

      # Verify memory exists in DB
      {:ok, memory} =
        Memory.get_memory_by_name(conversation.id, "deadline",
          actor: %Magus.Agents.Support.AiAgent{}
        )

      assert memory.summary == "Project deadline is Friday"
      assert memory.content["day"] == "Friday"
    end

    test "defaults scope to user" do
      %{user: user, context: context} = create_test_context()

      params = %{name: "timezone", summary: "User is in CET"}

      assert {:ok, result} = SetMemory.run(params, context)
      assert result.status == "created"
      assert result.scope == "user"

      actor = %Magus.Accounts.User{id: user.id}
      assert {:ok, _} = Memory.get_user_memory_by_name(nil, "timezone", actor: actor)
    end
  end

  describe "updating existing memories" do
    test "updates existing user memory (upsert)" do
      %{user: user, context: context} = create_test_context()

      # Create initial memory
      Memory.create_user_memory(
        user.id,
        nil,
        "preferred_language",
        %{summary: "User prefers Python", content: %{"language" => "Python"}},
        actor: %Magus.Agents.Support.AiAgent{}
      )

      # Now upsert via tool
      params = %{
        name: "preferred_language",
        summary: "User prefers TypeScript",
        content: %{"language" => "TypeScript"},
        scope: "user"
      }

      assert {:ok, result} = SetMemory.run(params, context)
      assert result.status == "updated"
      assert result.name == "preferred_language"

      # Verify updated
      actor = %Magus.Accounts.User{id: user.id}
      {:ok, memory} = Memory.get_user_memory_by_name(nil, "preferred_language", actor: actor)
      assert memory.summary == "User prefers TypeScript"
      assert memory.content["language"] == "TypeScript"
    end

    test "updates existing local memory (upsert)" do
      %{user: user, conversation: conversation, context: context} = create_test_context()

      # Create initial memory
      Memory.create_memory(
        conversation.id,
        user.id,
        "status",
        %{summary: "Task is pending", content: %{"status" => "pending"}},
        actor: %Magus.Agents.Support.AiAgent{}
      )

      # Now upsert via tool
      params = %{
        name: "status",
        summary: "Task is complete",
        content: %{"status" => "complete"},
        scope: "local"
      }

      assert {:ok, result} = SetMemory.run(params, context)
      assert result.status == "updated"

      # Verify updated
      {:ok, memory} =
        Memory.get_memory_by_name(conversation.id, "status",
          actor: %Magus.Agents.Support.AiAgent{}
        )

      assert memory.summary == "Task is complete"
      assert memory.content["status"] == "complete"
    end

    test "merges content on update rather than replacing" do
      %{user: user, context: context} = create_test_context()

      Memory.create_user_memory(
        user.id,
        nil,
        "preferences",
        %{summary: "User preferences", content: %{"theme" => "dark", "font" => "mono"}},
        actor: %Magus.Agents.Support.AiAgent{}
      )

      params = %{
        name: "preferences",
        summary: "User preferences updated",
        content: %{"theme" => "light"},
        scope: "user"
      }

      assert {:ok, %{status: "updated"}} = SetMemory.run(params, context)

      actor = %Magus.Accounts.User{id: user.id}
      {:ok, memory} = Memory.get_user_memory_by_name(nil, "preferences", actor: actor)
      # theme updated, font preserved
      assert memory.content["theme"] == "light"
      assert memory.content["font"] == "mono"
    end
  end

  describe "LLM string-key params" do
    test "handles string-keyed params from LLM" do
      %{context: context} = create_test_context()

      params = %{"name" => "timezone", "summary" => "User is in CET"}
      assert {:ok, result} = SetMemory.run(params, context)
      assert result.status == "created"
      assert result.name == "timezone"
    end

    test "handles JSON-encoded content string from LLM" do
      %{user: user, context: context} = create_test_context()

      params = %{
        name: "prefs",
        summary: "User preferences",
        content: ~s({"theme": "dark"})
      }

      assert {:ok, %{status: "created"}} = SetMemory.run(params, context)

      actor = %Magus.Accounts.User{id: user.id}
      {:ok, memory} = Memory.get_user_memory_by_name(nil, "prefs", actor: actor)
      assert memory.content["theme"] == "dark"
    end
  end

  describe "agent isolation" do
    test "blocks global scope when can_write_global_memories is false" do
      %{context: context} = create_test_context()
      isolated_context = Map.put(context, :can_write_global_memories, false)

      params = %{name: "test_mem", summary: "Test", scope: "user"}
      assert {:ok, result} = SetMemory.run(params, isolated_context)
      assert result.error =~ "cannot create or modify global memories"
    end

    test "allows local scope when can_write_global_memories is false" do
      %{context: context} = create_test_context()
      isolated_context = Map.put(context, :can_write_global_memories, false)

      params = %{name: "local_mem", summary: "Local test", scope: "local"}
      assert {:ok, result} = SetMemory.run(params, isolated_context)
      assert result.status == "created"
      assert result.scope == "local"
    end

    test "allows global scope when can_write_global_memories is true" do
      %{context: context} = create_test_context()
      allowed_context = Map.put(context, :can_write_global_memories, true)

      params = %{name: "global_mem", summary: "Global test", scope: "user"}
      assert {:ok, result} = SetMemory.run(params, allowed_context)
      assert result.status == "created"
      assert result.scope == "user"
    end

    test "defaults to allowed when isolation flag is absent" do
      %{context: context} = create_test_context()

      params = %{name: "default_mem", summary: "Default access", scope: "user"}
      assert {:ok, result} = SetMemory.run(params, context)
      assert result.status == "created"
    end
  end

  describe "error handling" do
    test "returns error for invalid scope" do
      %{context: context} = create_test_context()

      params = %{name: "test", summary: "test", scope: "invalid"}
      assert {:ok, result} = SetMemory.run(params, context)
      assert result.error =~ "Invalid scope"
    end

    test "returns error for missing context" do
      params = %{name: "test", summary: "test"}
      assert {:ok, result} = SetMemory.run(params, %{})
      assert result.error =~ "Missing required context"
    end

    test "returns error when local scope missing conversation_id" do
      params = %{name: "test", summary: "test", scope: "local"}
      assert {:ok, result} = SetMemory.run(params, %{user_id: Ash.UUIDv7.generate()})
      assert result.error =~ "Missing required context"
    end
  end
end
