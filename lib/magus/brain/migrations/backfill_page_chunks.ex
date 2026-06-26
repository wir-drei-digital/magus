defmodule Magus.Brain.Migrations.BackfillPageChunks do
  @moduledoc """
  Phase B backfill worker: for each page with a non-null `body` and zero
  rows in `brain_page_chunks`, chunk the body via `Magus.Brain.Chunker`
  and bulk-insert chunks with `embedding: nil`. The embeddings are
  filled in asynchronously by the ash_oban `generate_embedding` trigger
  on `Magus.Brain.PageChunk` (filter: `is_nil(embedding)`).

  Idempotent and auto-disabling: only picks up pages with no chunks,
  so a re-run on a fully-chunked page does nothing. Replaces all
  chunks for a page is NOT this worker's job — that's the Phase C
  save pipeline (`update_body` after-action diff + re-chunk).
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
    pages = pending_pages(batch_size)
    Enum.each(pages, &chunk_one/1)
    {:ok, length(pages)}
  end

  defp pending_pages(limit) do
    from(p in "brain_pages",
      left_join: c in "brain_page_chunks",
      on: c.page_id == p.id,
      where: not is_nil(p.body),
      where: p.body != "",
      where: is_nil(p.deleted_at),
      where: is_nil(c.id),
      select: %{id: p.id, body: p.body},
      group_by: [p.id, p.body, p.inserted_at],
      order_by: [asc: p.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp chunk_one(%{id: page_id, body: body}) do
    now = DateTime.utc_now()

    rows =
      body
      |> Chunker.chunk()
      |> Enum.map(fn %{content: content, index: idx, token_count: tokens} ->
        %{
          id: new_uuid_bin(),
          page_id: page_id,
          index: idx,
          content: content,
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
        Repo.insert_all("brain_page_chunks", rows, on_conflict: :nothing)
        :ok
    end
  rescue
    e ->
      Logger.warning(
        "BackfillPageChunks: failed for page #{inspect(page_id)}: #{Exception.message(e)}"
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
