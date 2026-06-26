defmodule Magus.Brain.Page.Changes.UpdateBodyDerivedState do
  @moduledoc """
  After-action pipeline for `Page.update_body`. Runs inside the same
  transaction as the body update, replacing the Phase B Oban rebuild
  workers (`RebuildPageLinks`, `RebuildPageSources`, `RebuildPageTags`,
  `ParseFrontmatter`, `BackfillPageChunks`).

  Steps (each idempotent):

    1. Parse frontmatter from the new body via `Magus.Brain.Frontmatter.parse/1`,
       drop the Phase B sentinel keys (`_no_frontmatter`, `_parse_error`,
       `_links_built_at`, `_sources_built_at`, `_tags_built_at`), and
       persist the result to `brain_pages.frontmatter` via raw
       `Repo.update_all` (we're already past the Ash write — going
       through Ash again would trip optimistic_lock and create a second
       paper-trail version).
    2. Rebuild `brain_page_links` from `[[Page Name]]` wikilinks. Targets
       resolve case-insensitively in the same brain; `[[msg:...]]` refs
       are skipped.
    3. Upsert `Magus.Brain.Source` rows for new URLs found in
       ```source fences (Phase C4 IngestWorker picks them up via the
       `:pending` ingest_status); then rebuild `brain_page_sources` with
       document-order `position`.
    4. Rebuild `brain_page_tags` from frontmatter `tags:` list plus
       inline `#tag` occurrences. Frontmatter wins on overlap.
    5. Delete and re-insert `brain_page_chunks` for the page (chunker
       strips frontmatter so embeddings are content-only). The
       `is_nil(embedding)` Oban trigger on `Magus.Brain.PageChunk`
       picks up the new rows asynchronously.

  All rebuild work uses raw Ecto (`Repo.delete_all` / `insert_all` /
  `update_all`) against the derived-index tables, mirroring the Phase B
  workers. The derived-index resources have `forbid_if always()` write
  policies, so going through Ash would require `authorize?: false`
  anyway — raw SQL is faster and bypasses the paper-trail / broadcast
  overhead we don't want for derived state.
  """

  use Ash.Resource.Change

  import Ecto.Query
  require Logger

  alias Magus.Brain.{BodyParser, Chunker, Frontmatter, Source}
  alias Magus.Repo

  # Phase B sentinel keys written by the cron rebuild workers. We strip
  # them on every save because the save pipeline owns rebuild now — a
  # leftover sentinel would suppress future cron ticks if the worker is
  # somehow re-enabled, and is meaningless once the inline rebuild ran.
  @sentinel_keys ~w(_no_frontmatter _parse_error _links_built_at _sources_built_at _tags_built_at)

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, page ->
      cleaned_matter = rebuild_all(page)
      # Reflect the SQL-side frontmatter write into the returned struct so
      # the caller sees the cache populated without an extra reload.
      {:ok, %{page | frontmatter: cleaned_matter}}
    end)
  end

  defp rebuild_all(page) do
    body = page.body || ""
    {matter, _rest} = parse_frontmatter_safe(body)
    cleaned = Map.drop(matter || %{}, @sentinel_keys)
    persist_frontmatter(page.id, cleaned)
    rebuild_links(page, body)
    rebuild_sources_and_page_sources(page, body)
    rebuild_tags(page, body, cleaned)
    rechunk(page, body)
    cleaned
  end

  # --- Frontmatter ---------------------------------------------------

  defp parse_frontmatter_safe(body) do
    case Frontmatter.parse(body) do
      {matter, rest} when is_map(matter) -> {matter, rest}
      # Malformed leading frontmatter — keep the body but cache empty
      # so derived indices still run. We don't surface the parse error
      # here because the body itself is already saved at this point and
      # we don't want to roll back over a YAML typo.
      {:error, :invalid_frontmatter} -> {%{}, body}
    end
  end

  defp persist_frontmatter(page_id, cleaned) do
    now = DateTime.utc_now()
    page_id_bin = dump_uuid(page_id)

    {1, _} =
      from(p in "brain_pages", where: p.id == ^page_id_bin)
      |> Repo.update_all(set: [frontmatter: cleaned, updated_at: now])

    :ok
  end

  # --- Links ---------------------------------------------------------

  defp rebuild_links(page, body) do
    now = DateTime.utc_now()
    page_id_bin = dump_uuid(page.id)
    targets = BodyParser.wikilinks(body)

    from(l in "brain_page_links", where: l.source_page_id == ^page_id_bin)
    |> Repo.delete_all()

    Enum.each(targets, fn target_title ->
      case resolve_target(page.brain_id, target_title) do
        nil ->
          :ok

        target_id ->
          Repo.insert_all(
            "brain_page_links",
            [
              %{
                id: new_uuid_bin(),
                source_page_id: page_id_bin,
                target_page_id: target_id,
                target_title_at_link_time: target_title,
                inserted_at: now
              }
            ],
            on_conflict: :nothing,
            conflict_target: [:source_page_id, :target_page_id]
          )
      end
    end)

    :ok
  end

  defp resolve_target(brain_id, target_title) do
    brain_id_bin = dump_uuid(brain_id)

    Repo.one(
      from(p in "brain_pages",
        where:
          p.brain_id == ^brain_id_bin and
            fragment("LOWER(?) = LOWER(?)", p.title, ^target_title) and
            is_nil(p.deleted_at),
        select: p.id,
        limit: 1
      )
    )
  end

  # --- Sources + PageSources -----------------------------------------

  defp rebuild_sources_and_page_sources(page, body) do
    now = DateTime.utc_now()
    page_id_bin = dump_uuid(page.id)
    urls = BodyParser.source_urls(body)

    # Upsert one Source row per new URL in :pending state. Existing
    # sources (matched on the (brain_id, url) identity) are reused so
    # we don't churn ingest_status on every save. Going through Ash so
    # that future `:create` extensions (validation, default fields)
    # still apply; the `forbid_if always()` write policy requires
    # `authorize?: false`.
    Enum.each(urls, fn url ->
      ensure_source(page.brain_id, url)
    end)

    from(s in "brain_page_sources", where: s.page_id == ^page_id_bin)
    |> Repo.delete_all()

    urls
    |> Enum.with_index()
    |> Enum.each(fn {url, position} ->
      case resolve_source(page.brain_id, url) do
        nil ->
          :ok

        source_id ->
          Repo.insert_all(
            "brain_page_sources",
            [
              %{
                id: new_uuid_bin(),
                page_id: page_id_bin,
                source_id: source_id,
                position: position,
                inserted_at: now
              }
            ],
            on_conflict: :nothing,
            conflict_target: [:page_id, :source_id]
          )
      end
    end)

    :ok
  end

  defp ensure_source(brain_id, url) do
    brain_id_bin = dump_uuid(brain_id)

    existing =
      Repo.one(
        from(s in "brain_sources",
          where: s.brain_id == ^brain_id_bin and s.url == ^url,
          select: s.id,
          limit: 1
        )
      )

    case existing do
      nil ->
        changeset =
          Ash.Changeset.for_create(Source, :create, %{
            brain_id: brain_id,
            url: url
          })

        case Ash.create(changeset, authorize?: false) do
          {:ok, _source} ->
            :ok

          {:error, error} ->
            Logger.warning(
              "UpdateBodyDerivedState: Source create failed for #{inspect(url)}: #{inspect(error)}"
            )

            :ok
        end

      _id ->
        :ok
    end
  end

  defp resolve_source(brain_id, url) do
    brain_id_bin = dump_uuid(brain_id)

    Repo.one(
      from(s in "brain_sources",
        where: s.brain_id == ^brain_id_bin and s.url == ^url,
        select: s.id,
        limit: 1
      )
    )
  end

  # --- Tags ----------------------------------------------------------

  defp rebuild_tags(page, body, matter) do
    now = DateTime.utc_now()
    page_id_bin = dump_uuid(page.id)
    brain_id_bin = dump_uuid(page.brain_id)

    frontmatter_tags =
      (matter || %{})
      |> Map.get("tags", [])
      |> List.wrap()
      |> Enum.map(&Frontmatter.normalize_tag(to_string(&1)))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    inline_tags = BodyParser.inline_tags(body)
    inline_only = Enum.reject(inline_tags, &(&1 in frontmatter_tags))

    rows =
      Enum.map(frontmatter_tags, fn t ->
        tag_row(t, "frontmatter", page_id_bin, brain_id_bin, now)
      end) ++
        Enum.map(inline_only, fn t ->
          tag_row(t, "inline", page_id_bin, brain_id_bin, now)
        end)

    from(t in "brain_page_tags", where: t.page_id == ^page_id_bin)
    |> Repo.delete_all()

    if rows != [] do
      Repo.insert_all("brain_page_tags", rows, on_conflict: :nothing)
    end

    :ok
  end

  defp tag_row(tag, source, page_id_bin, brain_id_bin, now) do
    %{
      id: new_uuid_bin(),
      tag: tag,
      source: source,
      page_id: page_id_bin,
      brain_id: brain_id_bin,
      inserted_at: now
    }
  end

  # --- Chunks --------------------------------------------------------

  defp rechunk(page, body) do
    now = DateTime.utc_now()
    page_id_bin = dump_uuid(page.id)

    # Always delete existing chunks so a body change consistently
    # replaces them. Even if the new body chunks to zero rows (empty
    # body), the deletion is the right behavior — stale chunks would
    # otherwise outlive a clear.
    from(c in "brain_page_chunks", where: c.page_id == ^page_id_bin)
    |> Repo.delete_all()

    rows =
      body
      |> Chunker.chunk()
      |> Enum.map(fn %{content: content, index: idx, token_count: tokens} ->
        %{
          id: new_uuid_bin(),
          page_id: page_id_bin,
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
  end

  # --- Helpers -------------------------------------------------------

  defp dump_uuid(<<_::128>> = bin), do: bin

  defp dump_uuid(s) when is_binary(s) do
    case Ecto.UUID.dump(s) do
      {:ok, bin} -> bin
      :error -> raise ArgumentError, "expected uuid, got #{inspect(s)}"
    end
  end

  defp new_uuid_bin do
    case Ecto.UUID.dump(Ash.UUIDv7.generate()) do
      {:ok, bin} -> bin
      :error -> raise "failed to dump UUID"
    end
  end
end
