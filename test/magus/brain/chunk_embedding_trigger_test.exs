defmodule Magus.Brain.ChunkEmbeddingTriggerTest do
  @moduledoc """
  Regression test for the `generate_embedding` Oban triggers on
  `Magus.Brain.PageChunk` / `Magus.Brain.SourceChunk`.

  AshOban runs the scheduler (and per-record worker) reads with
  `authorize?: AshOban.authorize?()` (defaults to `true`) and `actor: nil`
  (no `actor_persister` is configured). If the trigger's read action is
  gated by `Magus.Brain.Checks.BrainAccessFilter`, the nil actor filters
  every row out, the scheduler enqueues zero workers, and chunks never
  get embedded.

  These tests assert the dedicated scheduler read action returns
  null-embedding chunks even under that exact `authorize?: true, actor: nil`
  invocation.
  """

  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Brain
  alias Magus.Brain.PageChunk
  alias Magus.Brain.Source
  alias Magus.Brain.SourceChunk

  require Ash.Query

  setup do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "Engineering"}, actor: user)
    %{user: user, brain: brain}
  end

  describe "PageChunk generate_embedding scheduler read" do
    test "finds null-embedding chunks with authorize?: true and no actor", %{
      user: user,
      brain: brain
    } do
      {:ok, page} = Brain.create_page(brain.id, %{title: "Distributed Systems"}, actor: user)

      {:ok, chunk} =
        PageChunk
        |> Ash.Changeset.for_create(:create, %{
          page_id: page.id,
          index: 0,
          content: "Raft consensus ensures linearizable writes across replicas.",
          token_count: 10
        })
        |> Ash.create(authorize?: false)

      ids =
        PageChunk
        |> Ash.Query.for_read(:read_for_embedding, %{}, authorize?: true, actor: nil)
        |> Ash.read!()
        |> Enum.map(& &1.id)

      assert chunk.id in ids
    end
  end

  describe "SourceChunk generate_embedding scheduler read" do
    test "finds null-embedding chunks with authorize?: true and no actor", %{
      user: _user,
      brain: brain
    } do
      {:ok, source} =
        Source
        |> Ash.Changeset.for_create(:create, %{
          brain_id: brain.id,
          url: "https://example.com/paper",
          title: "A Paper"
        })
        |> Ash.create(authorize?: false)

      {:ok, chunk} =
        SourceChunk
        |> Ash.Changeset.for_create(:create, %{
          source_id: source.id,
          index: 0,
          content: "Attention is all you need, the transformer paper argues.",
          token_count: 10
        })
        |> Ash.create(authorize?: false)

      ids =
        SourceChunk
        |> Ash.Query.for_read(:read_for_embedding, %{}, authorize?: true, actor: nil)
        |> Ash.read!()
        |> Enum.map(& &1.id)

      assert chunk.id in ids
    end
  end
end
