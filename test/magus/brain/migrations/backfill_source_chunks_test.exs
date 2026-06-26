defmodule Magus.Brain.Migrations.BackfillSourceChunksTest do
  use Magus.DataCase, async: true

  import Ecto.Query
  import Magus.Generators

  alias Magus.Brain
  alias Magus.Brain.Migrations.BackfillSourceChunks
  alias Magus.Repo

  setup do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "B"}, actor: user)
    %{user: user, brain: brain}
  end

  defp create_source(brain_id, attrs) do
    Ash.create!(
      Ash.Changeset.for_create(
        Magus.Brain.Source,
        :from_legacy_block,
        Map.merge(
          %{brain_id: brain_id, url: "https://example.com", ingest_status: :ingested},
          attrs
        )
      ),
      authorize?: false
    )
  end

  defp chunk_count(source_id) do
    source_id_bin = Ecto.UUID.dump!(source_id)

    Repo.one(
      from(c in "brain_source_chunks", where: c.source_id == ^source_id_bin, select: count(c.id))
    )
  end

  describe "run_batch/1" do
    test "chunks ingested_content and inserts with embedding: nil", %{brain: brain} do
      source = create_source(brain.id, %{ingested_content: "Para one.\n\nPara two."})

      assert {:ok, 1} = BackfillSourceChunks.run_batch()
      assert chunk_count(source.id) >= 1
    end

    test "is idempotent on a fully-chunked source", %{brain: brain} do
      source = create_source(brain.id, %{ingested_content: "Body."})

      assert {:ok, 1} = BackfillSourceChunks.run_batch()
      before_count = chunk_count(source.id)
      assert {:ok, 0} = BackfillSourceChunks.run_batch()
      assert chunk_count(source.id) == before_count
    end

    test "skips sources with NULL ingested_content", %{brain: brain} do
      _source = create_source(brain.id, %{ingest_status: :pending})

      assert {:ok, 0} = BackfillSourceChunks.run_batch()
    end

    test "skips sources with empty-string ingested_content", %{brain: brain} do
      source = create_source(brain.id, %{ingested_content: ""})

      assert {:ok, 0} = BackfillSourceChunks.run_batch()
      assert chunk_count(source.id) == 0
    end
  end
end
