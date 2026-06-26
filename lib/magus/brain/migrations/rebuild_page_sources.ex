defmodule Magus.Brain.Migrations.RebuildPageSources do
  @moduledoc """
  Phase B backfill worker: for each page with body, parse ` ```source `
  fences via `Magus.Brain.BodyParser.source_urls/1`, look up matching
  `Magus.Brain.Source` rows by `(brain_id, url)`, and upsert into
  `brain_page_sources` with `position` matching document order.

  Depends on `BackfillSources` having run for the brain — sources
  referenced from a body but with no `Source` row yet are skipped (they
  show up as `[[broken-source]]` style in the UI later).

  Idempotent + auto-disabling via the `frontmatter._sources_built_at`
  sentinel. See `RebuildPageLinks` for the rebuild pattern.
  """

  use Oban.Worker,
    queue: :brain_backfill,
    max_attempts: 3

  import Ecto.Query
  require Logger

  alias Magus.Brain.BodyParser
  alias Magus.Repo

  @batch_size 50

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: run_batch()

  @spec run_batch(integer()) :: {:ok, non_neg_integer()}
  def run_batch(batch_size \\ @batch_size) do
    pages = pending_pages(batch_size)
    Enum.each(pages, &rebuild_one/1)
    {:ok, length(pages)}
  end

  defp pending_pages(limit) do
    from(p in "brain_pages",
      where: not is_nil(p.body),
      where: p.body != "",
      where: is_nil(p.deleted_at),
      where: fragment("? \\? '_sources_built_at'", p.frontmatter) == false,
      select: %{id: p.id, brain_id: p.brain_id, body: p.body, frontmatter: p.frontmatter},
      order_by: [asc: p.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp rebuild_one(page) do
    now = DateTime.utc_now()
    urls = BodyParser.source_urls(page.body)

    Repo.transaction(fn ->
      from(s in "brain_page_sources", where: s.page_id == ^page.id) |> Repo.delete_all()

      # Only set the sentinel when every source URL resolved to an existing
      # Magus.Brain.Source row. If BackfillSources hasn't seeded the source
      # yet, the next cron tick retries (mirrors RebuildPageLinks).
      all_resolved =
        urls
        |> Enum.with_index()
        |> Enum.reduce(true, fn {url, position}, acc ->
          case resolve_source(page.brain_id, url) do
            nil ->
              false

            source_id ->
              Repo.insert_all(
                "brain_page_sources",
                [
                  %{
                    id: new_uuid_bin(),
                    page_id: page.id,
                    source_id: source_id,
                    position: position,
                    inserted_at: now
                  }
                ],
                on_conflict: :nothing,
                conflict_target: [:page_id, :source_id]
              )

              acc
          end
        end)

      if all_resolved do
        mark_built(page.id, page.frontmatter, now)
      else
        Logger.debug(
          "RebuildPageSources: page #{inspect(page.id)} has unresolved source URLs; not setting sentinel"
        )
      end
    end)

    :ok
  rescue
    e ->
      Logger.warning(
        "RebuildPageSources: failed for page #{inspect(page.id)}: #{Exception.message(e)}"
      )

      :ok
  end

  defp resolve_source(brain_id, url) do
    Repo.one(
      from(s in "brain_sources",
        where: s.brain_id == ^brain_id and s.url == ^url,
        select: s.id,
        limit: 1
      )
    )
  end

  defp mark_built(page_id, frontmatter, now) do
    updated = Map.put(frontmatter || %{}, "_sources_built_at", DateTime.to_iso8601(now))

    {1, _} =
      from(p in "brain_pages", where: p.id == ^page_id)
      |> Repo.update_all(set: [frontmatter: updated, updated_at: now])

    :ok
  end

  defp new_uuid_bin do
    case Ecto.UUID.dump(Ash.UUIDv7.generate()) do
      {:ok, bin} -> bin
      :error -> raise "failed to dump UUID"
    end
  end
end
