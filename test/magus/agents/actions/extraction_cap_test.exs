defmodule Magus.Agents.Actions.ExtractionCapTest do
  @moduledoc """
  Tests for the per-conversation memory cap enforced at extraction time
  (`ExtractTurnMemories.enforce_conversation_cap/1`).

  Not async: overrides the `:magus, Magus.Memory` app env
  (`max_memories_per_conversation`) for the duration of the test so a small
  number of seed rows can exceed the cap. That override is process-global
  and would bleed into concurrently running async tests in other files, so
  this file (and only this test) runs synchronously.
  """
  use Magus.ResourceCase, async: false

  import Mox

  alias Magus.Agents.Actions.ExtractTurnMemories
  alias Magus.Memory, as: MemoryDomain
  alias Magus.Test.Mocks.LLMMock
  alias Magus.Test.MockResponses

  setup :verify_on_exit!

  setup do
    previous = Application.get_env(:magus, Magus.Memory)

    Application.put_env(
      :magus,
      Magus.Memory,
      Keyword.put(previous, :max_memories_per_conversation, 5)
    )

    on_exit(fn ->
      Application.put_env(:magus, Magus.Memory, previous)
    end)

    :ok
  end

  describe "extraction evicts over the cap" do
    test "evicts the least recently updated local memories over the cap" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      cap = Magus.Config.max_memories_per_conversation()
      assert cap == 5

      # Seed `cap` local memories, oldest first, with distinct updated_at
      # timestamps so sort order is deterministic regardless of clock
      # resolution.
      seed_names = for i <- 1..cap, do: "Seed Memory #{i}"

      seed_names
      |> Enum.with_index()
      |> Enum.each(fn {name, index} ->
        {:ok, memory} =
          MemoryDomain.create_memory(
            conv.id,
            user.id,
            name,
            %{summary: "seed #{index}", content: %{}},
            actor: %Magus.Agents.Support.AiAgent{}
          )

        backdate = DateTime.add(DateTime.utc_now(), -(cap - index) * 60, :second)
        {:ok, uuid_binary} = Ecto.UUID.dump(memory.id)

        Magus.Repo.query!(
          "UPDATE memories SET updated_at = $1 WHERE id = $2",
          [backdate, uuid_binary]
        )
      end)

      {:ok, seeded} = MemoryDomain.list_memories_for_conversation(conv.id, actor: user)
      assert length(seeded) == cap

      # Mock the LLM to return 2 new extractions.
      expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        MockResponses.generate_object_response(%{
          "extractions" => [
            %{
              "name" => "New Memory 1",
              "summary" => "fresh fact one",
              "content" => %{},
              "reason" => "stated in turn"
            },
            %{
              "name" => "New Memory 2",
              "summary" => "fresh fact two",
              "content" => %{},
              "reason" => "stated in turn"
            }
          ]
        })
      end)

      user_message =
        String.duplicate("Here is a new important fact you should remember for later. ", 2)

      agent_response =
        String.duplicate("Got it, I will keep both of those facts in mind going forward. ", 2)

      assert {:ok, result} =
               ExtractTurnMemories.run(
                 %{
                   user_id: user.id,
                   conversation_id: conv.id,
                   user_message: user_message,
                   agent_response: agent_response
                 },
                 %{}
               )

      assert result.extractions_applied == 2
      assert result.extractions_skipped == 0
      assert result.memories_evicted == 2

      {:ok, final_memories} =
        MemoryDomain.list_memories_for_conversation(conv.id, actor: user)

      assert length(final_memories) == cap

      final_names = MapSet.new(final_memories, & &1.name)

      # The two oldest seed memories (index 0, 1) are gone.
      refute MapSet.member?(final_names, "Seed Memory 1")
      refute MapSet.member?(final_names, "Seed Memory 2")

      # The remaining seed memories survive.
      assert MapSet.member?(final_names, "Seed Memory 3")
      assert MapSet.member?(final_names, "Seed Memory 4")
      assert MapSet.member?(final_names, "Seed Memory 5")

      # The 2 new extractions exist.
      assert MapSet.member?(final_names, "New Memory 1")
      assert MapSet.member?(final_names, "New Memory 2")
    end
  end
end
