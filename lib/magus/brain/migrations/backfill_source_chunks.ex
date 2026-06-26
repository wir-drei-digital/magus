defmodule Magus.Brain.Migrations.BackfillSourceChunks do
  @moduledoc """
  Phase B backfill worker: for each `Magus.Brain.Source` with non-null
  `ingested_content` and zero rows in `brain_source_chunks`, chunk the
  content and bulk-insert chunks with `embedding: nil`. The embeddings
  are filled in asynchronously by the ash_oban `generate_embedding`
  trigger on `Magus.Brain.SourceChunk`.

  Idempotent and auto-disabling. Mirrors `BackfillPageChunks` but reads
  from `brain_sources.ingested_content` instead of `brain_pages.body`.
  """

  use Oban.Worker,
    queue: :brain_backfill,
    max_attempts: 3

  import Ecto.Query
  require Logger

  alias Magus.Brain.Chunker
  alias Magus.Repo

  @batch_size 50

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: run_batch()

  @spec run_batch(integer()) :: {:ok, non_neg_integer()}
  def run_batch(batch_size \\ @batch_size) do
    sources = pending_sources(batch_size)
    Enum.each(sources, &chunk_one/1)
    {:ok, length(sources)}
  end

  defp pending_sources(limit) do
    from(s in "brain_sources",
      left_join: c in "brain_source_chunks",
      on: c.source_id == s.id,
      where: not is_nil(s.ingested_content),
      where: s.ingested_content != "",
      where: is_nil(c.id),
      select: %{id: s.id, ingested_content: s.ingested_content},
      group_by: [s.id, s.ingested_content, s.inserted_at],
      order_by: [asc: s.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp chunk_one(%{id: source_id, ingested_content: content}) do
    now = DateTime.utc_now()

    rows =
      content
      |> Chunker.chunk()
      |> Enum.map(fn %{content: c, index: idx, token_count: tokens} ->
        %{
          id: new_uuid_bin(),
          source_id: source_id,
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
        "BackfillSourceChunks: failed for source #{inspect(source_id)}: #{Exception.message(e)}"
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
