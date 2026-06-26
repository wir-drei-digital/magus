defmodule Magus.Agents.Actions.MergeMemoriesTest do
  @moduledoc """
  Tests for the MergeMemories action (cluster and merge related memories).
  """
  use Magus.ResourceCase, async: true

  import Mox

  alias Magus.Agents.Actions.MergeMemories
  alias Magus.Memory
  alias Magus.Test.Mocks.LLMMock
  alias Magus.Test.MockResponses

  @actor %Magus.Agents.Support.AiAgent{}

  setup :verify_on_exit!

  describe "run/2 - user-scope memories" do
    test "returns zero counts when fewer than min_memories_to_merge memories exist" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      # Create only 2 user-scope memories (below default threshold of 3)
      for name <- ["Memory A", "Memory B"] do
        Memory.create_user_memory(
          user.id,
          nil,
          name,
          %{summary: "Summary for #{name}", content: %{"key" => name}},
          actor: @actor
        )
      end

      # Also create a local memory to ensure it doesn't count toward user-scope threshold
      Memory.create_memory(
        conv.id,
        user.id,
        "Local Only",
        %{summary: "Local", content: %{}},
        actor: @actor
      )

      result = MergeMemories.run(%{user_id: user.id, skip_local: true}, %{})

      assert {:ok, %{global_merged_count: 0, local_merged_count: 0}} = result
    end

    test "merges user-scope memories when LLM identifies groups" do
      user = generate(user())

      # Create 3 user-scope memories
      memories =
        for name <- ["Coding Preferences", "Code Style", "IDE Settings"] do
          {:ok, mem} =
            Memory.create_user_memory(
              user.id,
              nil,
              name,
              %{summary: "Summary for #{name}", content: %{"key" => name}},
              actor: @actor
            )

          mem
        end

      [m1, m2, _m3] = memories

      # Mock LLM to merge first two memories
      expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        MockResponses.generate_object_response(%{
          "merge_groups" => [
            %{
              "category" => "coding_style",
              "memory_ids" => [m1.id, m2.id],
              "merged_name" => "Coding Style",
              "merged_summary" => "Combined coding preferences and style settings",
              "merged_content" => %{
                "preferences" => "Coding Preferences",
                "style" => "Code Style"
              },
              "reason" => "Both memories cover coding style preferences"
            }
          ],
          "reasoning" => "Two memories about coding style were merged"
        })
      end)

      result = MergeMemories.run(%{user_id: user.id, skip_local: true}, %{})

      assert {:ok, %{global_merged_count: 1, local_merged_count: 0}} = result

      # Verify source memories were deactivated
      {:ok, active_globals} =
        Memory.list_user_memories(nil, actor: %Magus.Accounts.User{id: user.id})

      active_names = Enum.map(active_globals, & &1.name)

      refute "Coding Preferences" in active_names
      refute "Code Style" in active_names
      assert "Coding Style" in active_names
      assert "IDE Settings" in active_names
    end

    test "deactivates source memories and creates version entry after merge" do
      user = generate(user())

      memories =
        for name <- ["Pref A", "Pref B", "Pref C"] do
          {:ok, mem} =
            Memory.create_user_memory(
              user.id,
              nil,
              name,
              %{summary: "Summary #{name}", content: %{"data" => name}},
              actor: @actor
            )

          mem
        end

      [m1, m2, m3] = memories

      expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        MockResponses.generate_object_response(%{
          "merge_groups" => [
            %{
              "category" => "preferences",
              "memory_ids" => [m1.id, m2.id, m3.id],
              "merged_name" => "All Preferences",
              "merged_summary" => "Combined preferences",
              "merged_content" => %{"all" => true},
              "reason" => "All related"
            }
          ],
          "reasoning" => "Merged all three"
        })
      end)

      {:ok, _} = MergeMemories.run(%{user_id: user.id, skip_local: true}, %{})

      # All source memories should be deactivated
      for mem <- memories do
        {:ok, reloaded} = Memory.get_memory(mem.id, authorize?: false)
        refute reloaded.is_active
      end

      # New merged memory should exist with a version entry
      {:ok, active_globals} =
        Memory.list_user_memories(nil, actor: %Magus.Accounts.User{id: user.id})

      merged = Enum.find(active_globals, &(&1.name == "All Preferences"))
      assert merged

      {:ok, versions} = Memory.list_versions_for_memory(merged.id, authorize?: false)
      assert length(versions) >= 1

      version = List.first(versions)
      assert version.changed_by == :system
      assert version.change_description =~ "Merged from:"
    end
  end

  describe "run/2 - local memories" do
    test "skips local merging when skip_local is true" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      for name <- ["Local A", "Local B", "Local C"] do
        Memory.create_memory(
          conv.id,
          user.id,
          name,
          %{summary: "Summary #{name}", content: %{}},
          actor: @actor
        )
      end

      # No LLM mock needed since skip_local should prevent any LLM call
      result = MergeMemories.run(%{user_id: user.id, skip_local: true}, %{})

      assert {:ok, %{local_merged_count: 0, conversations_processed: 0}} = result
    end

    test "marks conversation last_memory_consolidation_at after processing" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      for name <- ["Local A", "Local B", "Local C"] do
        Memory.create_memory(
          conv.id,
          user.id,
          name,
          %{summary: "Summary #{name}", content: %{}},
          actor: @actor
        )
      end

      # Mock LLM returning empty merge groups (no merges needed)
      expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        MockResponses.generate_object_response(%{
          "merge_groups" => [],
          "reasoning" => "No merges needed"
        })
      end)

      {:ok, _} = MergeMemories.run(%{user_id: user.id}, %{})

      # Verify conversation was marked as consolidated
      {:ok, updated_conv} = Magus.Chat.get_conversation(conv.id, authorize?: false)
      assert updated_conv.last_memory_consolidation_at != nil
    end

    test "merges local memories when LLM identifies groups" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      memories =
        for name <- ["Task List", "Project Tasks", "Sprint Goals"] do
          {:ok, mem} =
            Memory.create_memory(
              conv.id,
              user.id,
              name,
              %{summary: "Summary for #{name}", content: %{"data" => name}},
              actor: @actor
            )

          mem
        end

      [m1, m2, _m3] = memories

      # Mock LLM to merge first two local memories
      expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        MockResponses.generate_object_response(%{
          "merge_groups" => [
            %{
              "category" => "project_context",
              "memory_ids" => [m1.id, m2.id],
              "merged_name" => "Project Tasks",
              "merged_summary" => "Combined task tracking",
              "merged_content" => %{"tasks" => "combined"},
              "reason" => "Both cover project task management"
            }
          ],
          "reasoning" => "Two task-related memories merged"
        })
      end)

      result = MergeMemories.run(%{user_id: user.id, skip_local: false}, %{})

      assert {:ok, %{local_merged_count: 1, conversations_processed: 1}} = result

      # Verify source memories were deactivated
      {:ok, active_locals} =
        Memory.list_memories_for_conversation(conv.id, authorize?: false)

      active_names = Enum.map(active_locals, & &1.name)

      refute "Task List" in active_names
      assert "Sprint Goals" in active_names
      # The merged memory should exist (name reused from group)
      assert "Project Tasks" in active_names
    end

    test "skips recently consolidated conversations" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      for name <- ["Local A", "Local B", "Local C"] do
        Memory.create_memory(
          conv.id,
          user.id,
          name,
          %{summary: "Summary #{name}", content: %{}},
          actor: @actor
        )
      end

      # Mark conversation as recently consolidated
      Magus.Chat.mark_memory_consolidated(
        conv,
        %{last_memory_consolidation_at: DateTime.utc_now()},
        authorize?: false
      )

      # No LLM mock needed since the conversation should be skipped
      result = MergeMemories.run(%{user_id: user.id, skip_local: false}, %{})

      assert {:ok, %{conversations_processed: 0}} = result
    end
  end

  describe "run/2 - error handling" do
    test "handles LLM errors gracefully for user-scope memories" do
      user = generate(user())

      for name <- ["Mem A", "Mem B", "Mem C"] do
        Memory.create_user_memory(
          user.id,
          nil,
          name,
          %{summary: "Summary #{name}", content: %{}},
          actor: @actor
        )
      end

      expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        {:error, %{error: "LLM unavailable"}}
      end)

      result = MergeMemories.run(%{user_id: user.id, skip_local: true}, %{})

      # Should return 0 merged, not crash
      assert {:ok, %{global_merged_count: 0}} = result
    end
  end

  describe "schema validation" do
    test "has correct schema definition" do
      schema = MergeMemories.schema()

      assert Keyword.has_key?(schema, :user_id)
      assert Keyword.has_key?(schema, :skip_local)
      assert Keyword.has_key?(schema, :min_memories_to_merge)
    end
  end
end
