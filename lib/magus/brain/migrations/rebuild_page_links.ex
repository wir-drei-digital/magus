defmodule Magus.Brain.Migrations.RebuildPageLinks do
  @moduledoc """
  Phase B backfill worker: for each page with a non-null body, parse
  `[[Page Name]]` wikilinks via `Magus.Brain.BodyParser.wikilinks/1`,
  resolve each target to a page in the same brain (case-insensitive
  title match), and upsert into `brain_page_links` with
  `target_title_at_link_time` captured at parse time.

  Idempotent: re-running on a page first nukes its existing
  `brain_page_links` rows (where it is the source page), then inserts
  the current set. Pages with no `[[...]]` wikilinks get an empty
  ruleset (no insert) and won't be touched again unless body changes.

  Auto-disable: uses the `frontmatter._links_built_at` sentinel to skip
  pages already processed. The Phase C `update_body` after-action
  rebuilds links inline and clears the sentinel so subsequent body
  edits trigger a fresh rebuild.
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
      where: fragment("? \\? '_links_built_at'", p.frontmatter) == false,
      select: %{id: p.id, brain_id: p.brain_id, body: p.body, frontmatter: p.frontmatter},
      order_by: [asc: p.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp rebuild_one(page) do
    now = DateTime.utc_now()
    targets = BodyParser.wikilinks(page.body)

    Repo.transaction(fn ->
      # Clear stale rows where this page is the source.
      from(l in "brain_page_links", where: l.source_page_id == ^page.id)
      |> Repo.delete_all()

      # Track whether EVERY referenced wikilink resolved. If any didn't, we
      # leave the sentinel unset so the next cron tick retries after the
      # target page lands (the new-page-race fix mirrors BackfillPageBody).
      all_resolved =
        Enum.reduce(targets, true, fn target_title, acc ->
          case resolve_target(page.brain_id, target_title) do
            nil ->
              false

            target_id ->
              Repo.insert_all(
                "brain_page_links",
                [
                  %{
                    id: new_uuid_bin(),
                    source_page_id: page.id,
                    target_page_id: target_id,
                    target_title_at_link_time: target_title,
                    inserted_at: now
                  }
                ],
                on_conflict: :nothing,
                conflict_target: [:source_page_id, :target_page_id]
              )

              acc
          end
        end)

      if all_resolved do
        mark_built(page.id, page.frontmatter, now)
      else
        Logger.debug(
          "RebuildPageLinks: page #{inspect(page.id)} has unresolved wikilinks; not setting sentinel"
        )
      end
    end)

    :ok
  rescue
    e ->
      Logger.warning(
        "RebuildPageLinks: failed for page #{inspect(page.id)}: #{Exception.message(e)}"
      )

      :ok
  end

  defp resolve_target(brain_id, target_title) do
    Repo.one(
      from(p in "brain_pages",
        where:
          p.brain_id == ^brain_id and
            fragment("LOWER(?) = LOWER(?)", p.title, ^target_title) and
            is_nil(p.deleted_at),
        select: p.id,
        limit: 1
      )
    )
  end

  defp mark_built(page_id, frontmatter, now) do
    updated = Map.put(frontmatter || %{}, "_links_built_at", DateTime.to_iso8601(now))

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
