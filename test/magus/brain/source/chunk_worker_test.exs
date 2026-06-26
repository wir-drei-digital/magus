defmodule Magus.Brain.Source.ChunkWorkerTest do
  use Magus.DataCase, async: true
  use Oban.Testing, repo: Magus.Repo

  import Ecto.Query
  import Magus.Generators

  alias Magus.Brain
  alias Magus.Brain.Source.ChunkWorker
  alias Magus.Repo

  setup do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "B"}, actor: user)
    %{user: user, brain: brain}
  end

  defp create_source(brain_id, attrs) do
    Ash.create!(
      Ash.Changeset.for_create(
        Brain.Source,
        :from_legacy_block,
        Map.merge(
          %{
            brain_id: brain_id,
            url: "https://example.com",
            ingest_status: :ingested
          },
          attrs
        )
      ),
      authorize?: false
    )
  end

  defp chunk_count(source_id) do
    source_id_bin = Ecto.UUID.dump!(source_id)

    Repo.one(
      from(c in "brain_source_chunks",
        where: c.source_id == ^source_id_bin,
        select: count(c.id)
      )
    )
  end

  defp run(source_id) do
    perform_job(ChunkWorker, %{"source_id" => source_id})
  end

  describe "perform/1" do
    test "chunks ingested_content into brain_source_chunks rows with embedding: nil", %{
      brain: brain
    } do
      source =
        create_source(brain.id, %{ingested_content: "Para one.\n\nPara two.\n\nPara three."})

      assert :ok = run(source.id)

      source_id_bin = Ecto.UUID.dump!(source.id)

      rows =
        Repo.all(
          from(c in "brain_source_chunks",
            where: c.source_id == ^source_id_bin,
            select: %{embedding: c.embedding, content: c.content}
          )
        )

      assert rows != []
      Enum.each(rows, fn r -> assert is_nil(r.embedding) end)
    end

    test "is idempotent (re-run deletes + re-inserts)", %{brain: brain} do
      source = create_source(brain.id, %{ingested_content: "Body content."})

      assert :ok = run(source.id)
      first = chunk_count(source.id)
      assert first >= 1

      assert :ok = run(source.id)
      assert chunk_count(source.id) == first
    end

    test "no-ops on nil ingested_content", %{brain: brain} do
      source = create_source(brain.id, %{ingest_status: :pending})
      assert source.ingested_content == nil

      assert :ok = run(source.id)
      assert chunk_count(source.id) == 0
    end

    test "no-ops on empty ingested_content", %{brain: brain} do
      source = create_source(brain.id, %{ingested_content: ""})

      assert :ok = run(source.id)
      assert chunk_count(source.id) == 0
    end

    test "no-ops on deleted source" do
      assert :ok = run(Ash.UUIDv7.generate())
    end
  end
end
