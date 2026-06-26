defmodule Magus.Agents.Actions.ConsolidateMemoriesTest do
  @moduledoc """
  Tests for the ConsolidateMemories action (decay stale memories, promote candidates).
  """
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Actions.ConsolidateMemories
  alias Magus.Memory

  describe "run/2" do
    test "returns zero counts when no memories need consolidation" do
      user = generate(user())

      result = ConsolidateMemories.run(%{user_id: user.id}, %{})

      assert {:ok, %{decayed_count: 0, promoted_count: 0}} = result
    end

    test "returns error for missing user_id" do
      result = ConsolidateMemories.run(%{user_id: nil}, %{})

      assert {:error, _} = result
    end

    test "decays stale memories" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      # Create a memory
      {:ok, memory} =
        Memory.create_memory(
          conv.id,
          user.id,
          "Stale Memory",
          %{summary: "Very old context"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      # Manually set updated_at to be stale (over 90 days ago)
      stale_date = DateTime.add(DateTime.utc_now(), -100, :day)
      {:ok, uuid_binary} = Ecto.UUID.dump(memory.id)

      Magus.Repo.query!(
        "UPDATE memories SET updated_at = $1 WHERE id = $2",
        [stale_date, uuid_binary]
      )

      result = ConsolidateMemories.run(%{user_id: user.id}, %{})

      assert {:ok, %{decayed_count: 1, promoted_count: _}} = result

      # Verify the memory was deactivated
      {:ok, memories} = Memory.list_memories_for_conversation(conv.id, authorize?: false)
      refute Enum.any?(memories, &(&1.name == "Stale Memory"))
    end

    test "does not decay recently updated memories" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      # Create a memory that was recently updated
      {:ok, _memory} =
        Memory.create_memory(
          conv.id,
          user.id,
          "Recent Memory",
          %{summary: "Fresh context"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      result = ConsolidateMemories.run(%{user_id: user.id}, %{})

      assert {:ok, %{decayed_count: 0, promoted_count: _}} = result

      # Verify the memory still exists
      {:ok, memories} = Memory.list_memories_for_conversation(conv.id, authorize?: false)
      assert Enum.any?(memories, &(&1.name == "Recent Memory"))
    end

    test "does not decay stale-updated but recently-accessed memories" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      # Create a memory
      {:ok, memory} =
        Memory.create_memory(
          conv.id,
          user.id,
          "Accessed Memory",
          %{summary: "Old but accessed"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      # Set updated_at to be stale (over 90 days ago)
      stale_date = DateTime.add(DateTime.utc_now(), -100, :day)
      # But set last_accessed_at to yesterday
      recent_date = DateTime.add(DateTime.utc_now(), -1, :day)
      {:ok, uuid_binary} = Ecto.UUID.dump(memory.id)

      Magus.Repo.query!(
        "UPDATE memories SET updated_at = $1, last_accessed_at = $2 WHERE id = $3",
        [stale_date, recent_date, uuid_binary]
      )

      result =
        ConsolidateMemories.run(%{user_id: user.id, skip_promotion: true, skip_merge: true}, %{})

      assert {:ok, %{decayed_count: 0}} = result

      # Verify the memory still exists
      {:ok, memories} = Memory.list_memories_for_conversation(conv.id, authorize?: false)
      assert Enum.any?(memories, &(&1.name == "Accessed Memory"))
    end

    test "full run includes merged_count in result" do
      user = generate(user())

      result = ConsolidateMemories.run(%{user_id: user.id}, %{})

      assert {:ok, %{decayed_count: 0, promoted_count: 0, merged_count: 0}} = result
    end

    test "skip_merge prevents merge step" do
      user = generate(user())

      result = ConsolidateMemories.run(%{user_id: user.id, skip_merge: true}, %{})

      assert {:ok, %{merged_count: 0}} = result
    end
  end

  describe "schema validation" do
    test "has correct schema definition" do
      schema = ConsolidateMemories.schema()

      assert Keyword.has_key?(schema, :user_id)
    end
  end
end
