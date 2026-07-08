defmodule Magus.Memory.MemoryTest do
  @moduledoc """
  Tests for the Memory domain resources.

  Tests cover:
  - Memory CRUD operations
  - Version creation on updates
  - Deep merge behavior for update_content
  - Validation boundaries (content size, summary length)
  - Identity constraint (unique name per conversation)
  - Authorization policies
  """
  use Magus.ResourceCase, async: true
  use Oban.Testing, repo: Magus.Repo

  alias Magus.Memory
  alias Magus.Chat

  describe "Memory.create" do
    test "creates memory with basic attributes" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, memory} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Test Memory",
          %{content: %{"key" => "value"}, summary: "A test memory"},
          actor: user
        )

      assert memory.name == "Test Memory"
      assert memory.content == %{"key" => "value"}
      assert memory.summary == "A test memory"
      assert memory.is_active == true
      assert memory.lock_version == 0
    end

    test "creates initial version on create" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, memory} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Versioned Memory",
          %{content: %{"data" => "initial"}, summary: "Initial version"},
          actor: user
        )

      {:ok, versions} = Memory.list_versions_for_memory(memory.id, authorize?: false)

      assert length(versions) == 1
      version = hd(versions)
      assert version.content == %{"data" => "initial"}
      assert version.version == 0
    end

    test "enqueues embedding job when summary provided" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, _memory} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Embedded Memory",
          %{summary: "This is a searchable summary"},
          actor: user
        )

      assert_enqueued(
        worker: Magus.Memory.Memory.Workers.GenerateEmbedding,
        queue: :memory_extraction
      )
    end
  end

  describe "Memory.set" do
    test "replaces content entirely" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, memory} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Set Test",
          %{content: %{"old" => "data"}},
          actor: user
        )

      # set_memory takes content as positional arg: set_memory(record, content, opts)
      {:ok, updated} =
        Memory.set_memory(memory, %{"new" => "data"}, actor: user)

      assert updated.content == %{"new" => "data"}
      refute Map.has_key?(updated.content, "old")
    end

    test "increments lock_version" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, memory} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Lock Test",
          %{content: %{}},
          actor: user
        )

      assert memory.lock_version == 0

      {:ok, updated} =
        Memory.set_memory(memory, %{"v" => 1}, actor: user)

      assert updated.lock_version == 1
    end

    test "creates new version on update" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, memory} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Version Test",
          %{content: %{"v" => 0}},
          actor: user
        )

      {:ok, _updated} =
        Memory.set_memory(memory, %{"v" => 1}, actor: user)

      {:ok, versions} = Memory.list_versions_for_memory(memory.id, authorize?: false)

      assert length(versions) == 2
      [latest, _initial] = versions
      assert latest.content == %{"v" => 1}
      assert latest.version == 1
    end
  end

  describe "Memory.clear" do
    test "empties content while keeping metadata" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, memory} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Clear Test",
          %{content: %{"data" => "will be cleared"}, summary: "Keep me"},
          actor: user
        )

      {:ok, cleared} = Memory.clear_memory(memory, actor: user)

      assert cleared.content == %{}
      assert cleared.summary == "Keep me"
      assert cleared.name == "Clear Test"
    end
  end

  describe "Memory.destroy" do
    test "destroy hard-deletes the row" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, memory} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Destroy Test",
          %{},
          actor: user
        )

      assert memory.is_active == true

      assert :ok = Memory.destroy_memory(memory, actor: user)

      assert {:error, _} = Memory.get_memory(memory.id, actor: user)
    end

    test "destroyed memory not returned by for_conversation" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, memory} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Hidden Test",
          %{},
          actor: user
        )

      assert :ok = Memory.destroy_memory(memory, actor: user)

      {:ok, memories} = Memory.list_memories_for_conversation(conversation.id, actor: user)

      assert Enum.empty?(memories)
    end
  end

  describe "Memory.by_name" do
    test "finds memory by name within conversation" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, _memory} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Find Me",
          %{content: %{"found" => true}},
          actor: user
        )

      {:ok, found} = Memory.get_memory_by_name(conversation.id, "Find Me", actor: user)

      assert found.name == "Find Me"
      assert found.content == %{"found" => true}
    end

    test "returns error for non-existent name" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      # get? true actions return NotFound error when no record exists
      {:error, %Ash.Error.Invalid{}} =
        Memory.get_memory_by_name(conversation.id, "Does Not Exist", actor: user)
    end
  end

  describe "unique name constraint" do
    test "prevents duplicate names in same conversation" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, _first} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Unique Name",
          %{},
          actor: user
        )

      {:error, error} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Unique Name",
          %{},
          actor: user
        )

      # Database constraint error for duplicate unique name
      assert %Ash.Error.Unknown{} = error
    end

    test "allows same name in different conversations" do
      user = generate(user())
      {:ok, conv1} = Chat.create_conversation(%{}, actor: user)
      {:ok, conv2} = Chat.create_conversation(%{}, actor: user)

      {:ok, _first} =
        Memory.create_memory(conv1.id, user.id, "Shared Name", %{}, actor: user)

      {:ok, second} =
        Memory.create_memory(conv2.id, user.id, "Shared Name", %{}, actor: user)

      assert second.name == "Shared Name"
    end

    test "allows reusing name after destroy" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, first} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Reusable Name",
          %{},
          actor: user
        )

      assert :ok = Memory.destroy_memory(first, actor: user)

      {:ok, second} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Reusable Name",
          %{content: %{"new" => true}},
          actor: user
        )

      assert second.name == "Reusable Name"
      assert second.content == %{"new" => true}
    end

    test "hard-delete then re-create with the same name succeeds" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, first} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "again",
          %{},
          actor: user
        )

      assert :ok = Memory.destroy_memory(first, actor: user)

      {:ok, second} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "again",
          %{},
          actor: user
        )

      assert second.name == "again"
    end
  end

  describe "validations" do
    test "rejects content exceeding max size" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      # Generate content larger than 8000 chars
      large_content = %{"data" => String.duplicate("x", 9000)}

      {:error, error} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Too Large",
          %{content: large_content},
          actor: user
        )

      assert %Ash.Error.Invalid{} = error
    end

    test "rejects summary exceeding max length" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      long_summary = String.duplicate("x", 600)

      {:error, error} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Long Summary",
          %{summary: long_summary},
          actor: user
        )

      assert %Ash.Error.Invalid{} = error
    end
  end

  describe "authorization" do
    test "user can read own memories" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, memory} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "My Memory",
          %{},
          actor: user
        )

      {:ok, read} = Memory.get_memory(memory.id, actor: user)

      assert read.id == memory.id
    end

    test "user cannot read other user's memories" do
      user1 = generate(user())
      user2 = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user1)

      {:ok, memory} =
        Memory.create_memory(
          conversation.id,
          user1.id,
          "Private Memory",
          %{},
          actor: user1
        )

      # Authorization returns NotFound rather than Forbidden to not leak existence
      {:error, %Ash.Error.Invalid{}} = Memory.get_memory(memory.id, actor: user2)
    end

    test "conversation member can read memories" do
      owner = generate(user())
      member = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, _} = Chat.enable_multiplayer(conversation, actor: owner)

      {:ok, membership} =
        Chat.add_conversation_member(conversation.id, member.id, %{}, authorize?: false)

      {:ok, _} = Chat.accept_conversation_invitation(membership, actor: member)

      {:ok, memory} =
        Memory.create_memory(
          conversation.id,
          owner.id,
          "Shared Memory",
          %{},
          actor: owner
        )

      {:ok, read} = Memory.get_memory(memory.id, actor: member)

      assert read.id == memory.id
    end
  end

  describe "user memory authorization" do
    test "user can create and read their own user-scope memories" do
      user = generate(user())

      {:ok, memory} =
        Memory.create_user_memory(
          user.id,
          nil,
          "My Global Preferences",
          %{content: %{"theme" => "dark"}, summary: "User preferences"},
          actor: user
        )

      assert memory.name == "My Global Preferences"
      assert memory.scope == :user
      assert memory.conversation_id == nil

      {:ok, memories} = Memory.list_user_memories(nil, actor: user)
      assert length(memories) == 1
      assert hd(memories).id == memory.id
    end

    test "user cannot read another user's global memories via list" do
      user1 = generate(user())
      user2 = generate(user())

      {:ok, _memory} =
        Memory.create_user_memory(
          user1.id,
          nil,
          "User1 Secret",
          %{content: %{"secret" => "data"}},
          actor: user1
        )

      # User2 listing their own global memories should not see user1's
      {:ok, memories} = Memory.list_user_memories(nil, actor: user2)
      assert Enum.empty?(memories)
    end

    test "user cannot access another user's user-scope memory by name" do
      user1 = generate(user())
      user2 = generate(user())

      {:ok, _memory} =
        Memory.create_user_memory(
          user1.id,
          nil,
          "Private Preferences",
          %{content: %{"private" => true}},
          actor: user1
        )

      # User2 trying to get user1's user-scope memory should fail
      # With actor(:id) filtering, user2 only sees their own memories, so this returns not found
      {:error, %Ash.Error.Invalid{}} =
        Memory.get_user_memory_by_name(nil, "Private Preferences", actor: user2)
    end

    test "user cannot read another user's user-scope memory by ID" do
      user1 = generate(user())
      user2 = generate(user())

      {:ok, memory} =
        Memory.create_user_memory(
          user1.id,
          nil,
          "Secret Global",
          %{content: %{"secret" => true}},
          actor: user1
        )

      # User2 trying to get memory by ID should fail (returns NotFound to not leak existence)
      {:error, %Ash.Error.Invalid{}} = Memory.get_memory(memory.id, actor: user2)
    end

    test "user memories from different users are completely isolated" do
      user1 = generate(user())
      user2 = generate(user())

      # Both users create a user-scope memory with the same name
      {:ok, memory1} =
        Memory.create_user_memory(
          user1.id,
          nil,
          "Coding Style",
          %{content: %{"indent" => 2}},
          actor: user1
        )

      {:ok, memory2} =
        Memory.create_user_memory(
          user2.id,
          nil,
          "Coding Style",
          %{content: %{"indent" => 4}},
          actor: user2
        )

      # Each user should only see their own
      {:ok, user1_memories} = Memory.list_user_memories(nil, actor: user1)
      {:ok, user2_memories} = Memory.list_user_memories(nil, actor: user2)

      assert length(user1_memories) == 1
      assert length(user2_memories) == 1
      assert hd(user1_memories).content == %{"indent" => 2}
      assert hd(user2_memories).content == %{"indent" => 4}
      assert memory1.id != memory2.id
    end

    test "user cannot update another user's user-scope memory" do
      user1 = generate(user())
      user2 = generate(user())

      {:ok, memory} =
        Memory.create_user_memory(
          user1.id,
          nil,
          "Protected Memory",
          %{content: %{"original" => true}},
          actor: user1
        )

      # User2 trying to update user1's memory should fail with Forbidden
      {:error, %Ash.Error.Forbidden{}} =
        Memory.set_memory(memory, %{"hacked" => true}, actor: user2)
    end

    test "user cannot clear another user's user-scope memory" do
      user1 = generate(user())
      user2 = generate(user())

      {:ok, memory} =
        Memory.create_user_memory(
          user1.id,
          nil,
          "Protected Memory",
          %{content: %{"important" => "data"}},
          actor: user1
        )

      # User2 trying to clear user1's memory should fail with Forbidden
      {:error, %Ash.Error.Forbidden{}} = Memory.clear_memory(memory, actor: user2)
    end

    test "user cannot destroy another user's user-scope memory" do
      user1 = generate(user())
      user2 = generate(user())

      {:ok, memory} =
        Memory.create_user_memory(
          user1.id,
          nil,
          "Protected Memory",
          %{content: %{"keep" => "me"}},
          actor: user1
        )

      # User2 trying to destroy user1's memory should fail with Forbidden
      {:error, %Ash.Error.Forbidden{}} = Memory.destroy_memory(memory, actor: user2)
    end
  end

  describe "confidence and kind" do
    test "creates memory with default confidence and kind" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, memory} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Default Fields",
          %{},
          actor: user
        )

      assert memory.confidence == 1.0
      assert memory.kind == :general
    end

    test "creates memory with custom confidence and kind" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, memory} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Custom Fields",
          %{confidence: 0.7, kind: :hypothesis},
          actor: user
        )

      assert memory.confidence == 0.7
      assert memory.kind == :hypothesis
    end

    test "supports all kind values" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      for kind <- [:general, :fact, :hypothesis, :observation, :summary, :preference] do
        {:ok, memory} =
          Memory.create_memory(
            conversation.id,
            user.id,
            "Kind #{kind}",
            %{kind: kind},
            actor: user
          )

        assert memory.kind == kind
      end
    end

    test "updates confidence and kind via set" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, memory} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Update Fields",
          %{content: %{"data" => true}, confidence: 0.5, kind: :hypothesis},
          actor: user
        )

      {:ok, updated} =
        Memory.set_memory(
          memory,
          %{"data" => true, "more" => true},
          %{confidence: 0.9, kind: :fact},
          actor: user
        )

      assert updated.confidence == 0.9
      assert updated.kind == :fact
    end
  end

  describe "kinds and structured_data" do
    setup do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
      %{user: user, conversation: conversation}
    end

    test "creates memory with goal kind", %{user: user, conversation: conversation} do
      memory =
        Memory.create_memory!(
          conversation.id,
          user.id,
          "my_goal",
          %{
            content: %{text: "Learn figure drawing"},
            summary: "Art goal",
            kind: :goal,
            structured_data: %{
              deadline: "2026-06-01",
              status: "active",
              progress: 0,
              milestones: ["gesture drawing", "anatomy basics", "full figure"]
            }
          },
          actor: user
        )

      assert memory.kind == :goal
      assert memory.structured_data["deadline"] == "2026-06-01"
      assert memory.structured_data["milestones"] |> length() == 3
    end

    test "creates memory with habit kind", %{user: user, conversation: conversation} do
      memory =
        Memory.create_memory!(
          conversation.id,
          user.id,
          "daily_drawing",
          %{
            content: %{text: "30 min figure drawing daily"},
            summary: "Drawing habit",
            kind: :habit,
            structured_data: %{frequency: "daily", target: 30, streak: 0, last_completed: nil}
          },
          actor: user
        )

      assert memory.kind == :habit
      assert memory.structured_data["frequency"] == "daily"
    end

    test "creates memory with topic kind", %{user: user, conversation: conversation} do
      memory =
        Memory.create_memory!(
          conversation.id,
          user.id,
          "color_theory",
          %{
            content: %{text: "Notes on color theory"},
            summary: "Color theory research",
            kind: :topic,
            structured_data: %{sources: [], confidence: 0.7}
          },
          actor: user
        )

      assert memory.kind == :topic
    end

    test "creates memory with reflection kind", %{user: user, conversation: conversation} do
      memory =
        Memory.create_memory!(
          conversation.id,
          user.id,
          "week_1_reflection",
          %{
            content: %{text: "First week went well"},
            summary: "Week 1 review",
            kind: :reflection,
            structured_data: %{period: "weekly", date: "2026-03-29"}
          },
          actor: user
        )

      assert memory.kind == :reflection
    end

    test "structured_data defaults to nil", %{user: user, conversation: conversation} do
      memory =
        Memory.create_memory!(
          conversation.id,
          user.id,
          "plain_memory",
          %{
            content: %{text: "just text"},
            summary: "Plain"
          },
          actor: user
        )

      assert memory.structured_data == nil
    end

    test "updates structured_data via set", %{user: user, conversation: conversation} do
      memory =
        Memory.create_memory!(
          conversation.id,
          user.id,
          "updatable",
          %{
            content: %{text: "goal"},
            summary: "A goal",
            kind: :goal,
            structured_data: %{progress: 0}
          },
          actor: user
        )

      updated =
        Memory.set_memory!(memory, %{text: "goal"}, %{structured_data: %{progress: 50}},
          actor: user
        )

      assert updated.structured_data["progress"] == 50
    end
  end

  describe "agent-scoped memories" do
    setup do
      user = generate(user())

      {:ok, agent} =
        Magus.Agents.create_custom_agent(
          %{name: "Test Agent", instructions: "You are a test agent."},
          actor: user
        )

      %{user: user, agent: agent}
    end

    test "creates agent-scoped memory", %{user: user, agent: agent} do
      {:ok, memory} =
        Memory.create_agent_memory(
          user.id,
          agent.id,
          %{
            name: "Agent Knowledge",
            content: %{"skill" => "testing"},
            summary: "Agent knowledge"
          },
          actor: user
        )

      assert memory.scope == :agent
      assert memory.custom_agent_id == agent.id
      assert memory.user_id == user.id
      assert memory.conversation_id == nil
      assert memory.name == "Agent Knowledge"
    end

    test "creates agent memory with confidence and kind", %{user: user, agent: agent} do
      {:ok, memory} =
        Memory.create_agent_memory(
          user.id,
          agent.id,
          %{name: "Agent Fact", confidence: 0.8, kind: :fact},
          actor: user
        )

      assert memory.confidence == 0.8
      assert memory.kind == :fact
    end

    test "for_agent lists only agent-scoped memories", %{user: user, agent: agent} do
      {:ok, _mem1} =
        Memory.create_agent_memory(
          user.id,
          agent.id,
          %{name: "Agent Mem 1", content: %{"a" => 1}},
          actor: user
        )

      {:ok, _mem2} =
        Memory.create_agent_memory(
          user.id,
          agent.id,
          %{name: "Agent Mem 2", content: %{"b" => 2}},
          actor: user
        )

      # Also create a user-scope memory to ensure isolation
      {:ok, _global} =
        Memory.create_user_memory(
          user.id,
          nil,
          "Global Mem",
          %{content: %{"g" => true}},
          actor: user
        )

      {:ok, agent_memories} =
        Memory.list_agent_memories(agent.id, authorize?: false)

      assert length(agent_memories) == 2
      assert Enum.all?(agent_memories, &(&1.scope == :agent))
      assert Enum.all?(agent_memories, &(&1.custom_agent_id == agent.id))
    end

    test "unique name per agent identity prevents duplicates", %{user: user, agent: agent} do
      {:ok, _first} =
        Memory.create_agent_memory(
          user.id,
          agent.id,
          %{name: "Unique Agent Name"},
          actor: user
        )

      {:error, _error} =
        Memory.create_agent_memory(
          user.id,
          agent.id,
          %{name: "Unique Agent Name"},
          actor: user
        )
    end

    test "same name allowed for different agents", %{user: user, agent: agent} do
      {:ok, agent2} =
        Magus.Agents.create_custom_agent(
          %{name: "Second Agent", instructions: "Another agent."},
          actor: user
        )

      {:ok, _mem1} =
        Memory.create_agent_memory(
          user.id,
          agent.id,
          %{name: "Shared Name"},
          actor: user
        )

      {:ok, mem2} =
        Memory.create_agent_memory(
          user.id,
          agent2.id,
          %{name: "Shared Name"},
          actor: user
        )

      assert mem2.name == "Shared Name"
      assert mem2.custom_agent_id == agent2.id
    end

    test "destroyed agent memory allows name reuse", %{user: user, agent: agent} do
      {:ok, first} =
        Memory.create_agent_memory(
          user.id,
          agent.id,
          %{name: "Reusable"},
          actor: user
        )

      assert :ok = Memory.destroy_memory(first, actor: user)

      {:ok, second} =
        Memory.create_agent_memory(
          user.id,
          agent.id,
          %{name: "Reusable", content: %{"new" => true}},
          actor: user
        )

      assert second.name == "Reusable"
      assert second.content == %{"new" => true}
    end

    test "for_agent excludes destroyed memories", %{user: user, agent: agent} do
      {:ok, mem} =
        Memory.create_agent_memory(
          user.id,
          agent.id,
          %{name: "Will Destroy"},
          actor: user
        )

      assert :ok = Memory.destroy_memory(mem, actor: user)

      {:ok, agent_memories} =
        Memory.list_agent_memories(agent.id, authorize?: false)

      assert Enum.empty?(agent_memories)
    end
  end
end
