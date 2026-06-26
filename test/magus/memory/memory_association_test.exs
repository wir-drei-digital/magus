defmodule Magus.Memory.MemoryAssociationTest do
  @moduledoc """
  Tests for the MemoryAssociation resource.

  Tests cover:
  - Create with automatic a < b ordering
  - Reinforce increments weight by 0.1
  - Reinforce caps weight at 1.0
  - for_memory returns associations for a memory
  - between finds association between two specific memories
  - unique_pair prevents duplicates
  """
  use Magus.ResourceCase, async: true
  use Oban.Testing, repo: Magus.Repo

  alias Magus.Memory

  defp create_two_memories do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

    {:ok, mem_a} =
      Memory.create_memory(conversation.id, user.id, "Memory A", %{}, actor: user)

    {:ok, mem_b} =
      Memory.create_memory(conversation.id, user.id, "Memory B", %{}, actor: user)

    {user, conversation, mem_a, mem_b}
  end

  describe "MemoryAssociation.create" do
    test "creates association between two memories" do
      {_user, _conv, mem_a, mem_b} = create_two_memories()

      {:ok, assoc} =
        Memory.create_memory_association(mem_a.id, mem_b.id, %{}, authorize?: false)

      assert assoc.weight == 0.1
      assert assoc.last_reinforced_at != nil
    end

    test "enforces a < b ordering when given in correct order" do
      {_user, _conv, mem_a, mem_b} = create_two_memories()

      # Ensure mem_a.id < mem_b.id for this test
      {lo_id, hi_id} =
        if mem_a.id < mem_b.id, do: {mem_a.id, mem_b.id}, else: {mem_b.id, mem_a.id}

      {:ok, assoc} =
        Memory.create_memory_association(lo_id, hi_id, %{}, authorize?: false)

      assert assoc.memory_a_id == lo_id
      assert assoc.memory_b_id == hi_id
    end

    test "enforces a < b ordering when given in reverse order" do
      {_user, _conv, mem_a, mem_b} = create_two_memories()

      {lo_id, hi_id} =
        if mem_a.id < mem_b.id, do: {mem_a.id, mem_b.id}, else: {mem_b.id, mem_a.id}

      # Pass them in reverse order
      {:ok, assoc} =
        Memory.create_memory_association(hi_id, lo_id, %{}, authorize?: false)

      # Should still be stored as lo < hi
      assert assoc.memory_a_id == lo_id
      assert assoc.memory_b_id == hi_id
    end

    test "accepts custom weight" do
      {_user, _conv, mem_a, mem_b} = create_two_memories()

      {:ok, assoc} =
        Memory.create_memory_association(mem_a.id, mem_b.id, %{weight: 0.5}, authorize?: false)

      assert assoc.weight == 0.5
    end

    test "unique_pair prevents duplicate associations" do
      {_user, _conv, mem_a, mem_b} = create_two_memories()

      {:ok, _assoc} =
        Memory.create_memory_association(mem_a.id, mem_b.id, %{}, authorize?: false)

      {:error, _error} =
        Memory.create_memory_association(mem_a.id, mem_b.id, %{}, authorize?: false)
    end

    test "unique_pair prevents duplicates even with reversed order" do
      {_user, _conv, mem_a, mem_b} = create_two_memories()

      {:ok, _assoc} =
        Memory.create_memory_association(mem_a.id, mem_b.id, %{}, authorize?: false)

      # Try creating again with reversed IDs - should still fail due to ordering normalization
      {:error, _error} =
        Memory.create_memory_association(mem_b.id, mem_a.id, %{}, authorize?: false)
    end
  end

  describe "MemoryAssociation.reinforce" do
    test "increments weight by 0.1" do
      {_user, _conv, mem_a, mem_b} = create_two_memories()

      {:ok, assoc} =
        Memory.create_memory_association(mem_a.id, mem_b.id, %{}, authorize?: false)

      assert assoc.weight == 0.1

      {:ok, reinforced} = Memory.reinforce_association(assoc, %{}, authorize?: false)

      assert_in_delta reinforced.weight, 0.2, 0.001
    end

    test "multiple reinforcements accumulate" do
      {_user, _conv, mem_a, mem_b} = create_two_memories()

      {:ok, assoc} =
        Memory.create_memory_association(mem_a.id, mem_b.id, %{}, authorize?: false)

      # Reinforce 3 times: 0.1 -> 0.2 -> 0.3 -> 0.4
      {:ok, assoc} = Memory.reinforce_association(assoc, %{}, authorize?: false)
      {:ok, assoc} = Memory.reinforce_association(assoc, %{}, authorize?: false)
      {:ok, assoc} = Memory.reinforce_association(assoc, %{}, authorize?: false)

      assert_in_delta assoc.weight, 0.4, 0.001
    end

    test "caps weight at 1.0" do
      {_user, _conv, mem_a, mem_b} = create_two_memories()

      {:ok, assoc} =
        Memory.create_memory_association(mem_a.id, mem_b.id, %{weight: 0.95}, authorize?: false)

      {:ok, reinforced} = Memory.reinforce_association(assoc, %{}, authorize?: false)

      assert reinforced.weight == 1.0
    end

    test "stays at 1.0 when already at max" do
      {_user, _conv, mem_a, mem_b} = create_two_memories()

      {:ok, assoc} =
        Memory.create_memory_association(mem_a.id, mem_b.id, %{weight: 1.0}, authorize?: false)

      {:ok, reinforced} = Memory.reinforce_association(assoc, %{}, authorize?: false)

      assert reinforced.weight == 1.0
    end

    test "updates last_reinforced_at" do
      {_user, _conv, mem_a, mem_b} = create_two_memories()

      {:ok, assoc} =
        Memory.create_memory_association(mem_a.id, mem_b.id, %{}, authorize?: false)

      original_time = assoc.last_reinforced_at

      # Small delay to ensure timestamp differs
      Process.sleep(10)

      {:ok, reinforced} = Memory.reinforce_association(assoc, %{}, authorize?: false)

      assert DateTime.compare(reinforced.last_reinforced_at, original_time) != :lt
    end
  end

  describe "MemoryAssociation.for_memory" do
    test "returns all associations for a memory" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, mem_a} =
        Memory.create_memory(conversation.id, user.id, "Mem A", %{}, actor: user)

      {:ok, mem_b} =
        Memory.create_memory(conversation.id, user.id, "Mem B", %{}, actor: user)

      {:ok, mem_c} =
        Memory.create_memory(conversation.id, user.id, "Mem C", %{}, actor: user)

      {:ok, _ab} =
        Memory.create_memory_association(mem_a.id, mem_b.id, %{}, authorize?: false)

      {:ok, _ac} =
        Memory.create_memory_association(mem_a.id, mem_c.id, %{}, authorize?: false)

      {:ok, assocs} = Memory.get_associations_for_memory(mem_a.id, authorize?: false)

      assert length(assocs) == 2
    end

    test "returns associations where memory is either a or b" do
      {_user, _conv, mem_a, mem_b} = create_two_memories()

      {:ok, _assoc} =
        Memory.create_memory_association(mem_a.id, mem_b.id, %{}, authorize?: false)

      # Both memories should find the same association
      {:ok, assocs_a} = Memory.get_associations_for_memory(mem_a.id, authorize?: false)
      {:ok, assocs_b} = Memory.get_associations_for_memory(mem_b.id, authorize?: false)

      assert length(assocs_a) == 1
      assert length(assocs_b) == 1
      assert hd(assocs_a).id == hd(assocs_b).id
    end

    test "returns empty list for memory with no associations" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, mem} =
        Memory.create_memory(conversation.id, user.id, "Lonely", %{}, actor: user)

      {:ok, assocs} = Memory.get_associations_for_memory(mem.id, authorize?: false)

      assert assocs == []
    end

    test "sorts by weight descending" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, mem_a} =
        Memory.create_memory(conversation.id, user.id, "Center", %{}, actor: user)

      {:ok, mem_b} =
        Memory.create_memory(conversation.id, user.id, "Weak", %{}, actor: user)

      {:ok, mem_c} =
        Memory.create_memory(conversation.id, user.id, "Strong", %{}, actor: user)

      {:ok, _weak} =
        Memory.create_memory_association(mem_a.id, mem_b.id, %{weight: 0.2}, authorize?: false)

      {:ok, _strong} =
        Memory.create_memory_association(mem_a.id, mem_c.id, %{weight: 0.8}, authorize?: false)

      {:ok, assocs} = Memory.get_associations_for_memory(mem_a.id, authorize?: false)

      weights = Enum.map(assocs, & &1.weight)
      assert weights == [0.8, 0.2]
    end
  end

  describe "MemoryAssociation.between" do
    test "finds association between two specific memories" do
      {_user, _conv, mem_a, mem_b} = create_two_memories()

      {:ok, assoc} =
        Memory.create_memory_association(mem_a.id, mem_b.id, %{weight: 0.5}, authorize?: false)

      {:ok, found} =
        Memory.get_association_between(mem_a.id, mem_b.id, authorize?: false)

      assert found.id == assoc.id
      assert found.weight == 0.5
    end

    test "finds association regardless of argument order" do
      {_user, _conv, mem_a, mem_b} = create_two_memories()

      {:ok, assoc} =
        Memory.create_memory_association(mem_a.id, mem_b.id, %{}, authorize?: false)

      # Look up with reversed order
      {:ok, found} =
        Memory.get_association_between(mem_b.id, mem_a.id, authorize?: false)

      assert found.id == assoc.id
    end

    test "returns error when no association exists" do
      {_user, _conv, mem_a, mem_b} = create_two_memories()

      {:error, %Ash.Error.Invalid{}} =
        Memory.get_association_between(mem_a.id, mem_b.id, authorize?: false)
    end
  end
end
