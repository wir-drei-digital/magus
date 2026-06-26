defmodule Magus.Brain.Migrations.BackfillPageBody do
  @moduledoc """
  Phase B backfill worker: for each page with `body IS NULL`, load its
  blocks, render to markdown via `BlockSerializer.to_markdown/1`, and
  set `body` via a direct `Repo.update_all` so AshPaperTrail does NOT
  fire (no version row per backfill page).

  Idempotent and auto-disabling: each tick claims at most `@batch_size`
  pages and exits when there are none left. Once every page has a body,
  cron ticks do zero work.

  Cron-scheduled every minute. Safe to delete the cron entry after a
  staging deploy confirms `COUNT(*) FROM brain_pages WHERE body IS NULL = 0`.
  """

  use Oban.Worker,
    queue: :brain_backfill,
    max_attempts: 3

  import Ecto.Query
  require Ash.Query
  require Logger

  alias Magus.Brain.BlockSerializer
  alias Magus.Repo

  @batch_size 50

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: run_batch()

  @doc """
  Backfills up to `@batch_size` pages in one pass. Returns `{:ok, count}`
  with the number of pages updated this tick (useful for tests / manual
  triggering).
  """
  @spec run_batch(integer()) :: {:ok, non_neg_integer()}
  def run_batch(batch_size \\ @batch_size) do
    pending_page_ids = pending_page_ids(batch_size)
    Enum.each(pending_page_ids, &backfill_one/1)
    {:ok, length(pending_page_ids)}
  end

  # A page needs (re-)backfill when:
  #   * body IS NULL — never been touched, or
  #   * body = "" AND blocks exist — caught the new-page race (the page was
  #     created during the A/B coexistence window, the cron ticked before any
  #     blocks landed, and we wrote an empty body; once blocks appear, re-render).
  # The second clause uses EXISTS (not COUNT) so Postgres can short-circuit.
  defp pending_page_ids(limit) do
    from(p in "brain_pages",
      where: is_nil(p.deleted_at),
      where:
        is_nil(p.body) or
          (p.body == "" and
             fragment("EXISTS (SELECT 1 FROM brain_blocks WHERE page_id = ?)", p.id)),
      select: p.id,
      limit: ^limit,
      order_by: [asc: p.inserted_at]
    )
    |> Repo.all()
  end

  defp backfill_one(page_id) do
    blocks =
      Magus.Brain.Block
      |> Ash.Query.filter(page_id == ^page_id)
      |> Ash.Query.sort(position: :asc)
      |> Ash.read!(authorize?: false)

    body = BlockSerializer.to_markdown(blocks)

    {1, _} =
      from(p in "brain_pages", where: p.id == ^page_id)
      |> Repo.update_all(set: [body: body, updated_at: DateTime.utc_now()])

    :ok
  rescue
    e ->
      Logger.warning(
        "BackfillPageBody: failed for page #{inspect(page_id)}: #{Exception.message(e)}"
      )

      :ok
  end
end
