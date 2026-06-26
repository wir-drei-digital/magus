defmodule Magus.Brain.Source.ChunkWorker do
  @moduledoc """
  Phase C4 chunker worker. For one `Magus.Brain.Source` with
  `ingested_content`, replaces its `brain_source_chunks` rows so the
  `is_nil(embedding)` Oban trigger on `Magus.Brain.SourceChunk` picks
  them up and fills in embeddings asynchronously.

  Mirrors `Magus.Brain.Migrations.BackfillSourceChunks` but processes a
  single source instead of a batch. Idempotent: re-running on the same
  source deletes the existing chunks and re-inserts.

  Enqueued by `Magus.Brain.Source.IngestWorker` after a successful URL
  fetch. Safe to enqueue manually for a re-chunk pass.
  """

  use Oban.Worker,
    queue: :brain_backfill,
    max_attempts: 3

  import Ecto.Query
  require Logger

  alias Magus.Brain
  alias Magus.Brain.Chunker
  alias Magus.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id}}) do
    case Brain.get_source(source_id, authorize?: false) do
      {:ok, source} ->
        chunk_one(source)

      # Source deleted between IngestWorker completion and ChunkWorker
      # pickup — nothing to do.
      {:error, _} ->
        :ok
    end
  end

  defp chunk_one(%{ingested_content: nil}), do: :ok
  defp chunk_one(%{ingested_content: ""}), do: :ok

  defp chunk_one(%{id: source_id, ingested_content: content}) do
    source_id_bin = Ecto.UUID.dump!(source_id)
    now = DateTime.utc_now()

    # Replace existing chunks so a re-ingest reflects the latest content.
    from(c in "brain_source_chunks", where: c.source_id == ^source_id_bin)
    |> Repo.delete_all()

    rows =
      content
      |> Chunker.chunk()
      |> Enum.map(fn %{content: c, index: idx, token_count: tokens} ->
        %{
          id: new_uuid_bin(),
          source_id: source_id_bin,
          index: idx,
          content: c,
          token_count: tokens,
          embedding: nil,
          inserted_at: now,
          updated_at: now
        }
      end)

    case rows do
      [] ->
        :ok

      rows ->
        Repo.insert_all("brain_source_chunks", rows, on_conflict: :nothing)
        :ok
    end
  rescue
    e ->
      Logger.warning(
        "Brain.Source.ChunkWorker: chunking failed for source #{inspect(source_id)}: " <>
          Exception.message(e)
      )

      :ok
  end

  defp new_uuid_bin do
    case Ecto.UUID.dump(Ash.UUIDv7.generate()) do
      {:ok, bin} -> bin
      :error -> raise "failed to dump UUID"
    end
  end
end
