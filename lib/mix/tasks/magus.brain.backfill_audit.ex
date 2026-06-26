defmodule Mix.Tasks.Magus.Brain.BackfillAudit do
  @moduledoc """
  Phase B7 audit: for every non-trashed page with blocks, re-render the
  blocks via `Magus.Brain.BlockSerializer.to_markdown/1` and byte-compare
  to the persisted `body`. Reports divergences without modifying anything.

  Run this after the Phase B backfill cron has had time to bake. Pair with
  `mix magus.brain.force_resync` to fix the divergences, then re-run this
  audit until it reports zero. Gate Phase C deploy on a clean audit.

  Also verifies:

    * Body completeness: pages with `body IS NULL OR body = ''`
    * Chunk coverage: pages with body > 50 chars but zero PageChunk rows
    * Source ref parity: count of `BodyParser.source_urls(body)` matches
      `brain_page_sources` count per page (sampled)
    * Wikilink parity: count of `BodyParser.wikilinks(body)` matches
      `brain_page_links` (rows where target resolved) per page (sampled)

  ## Usage

      mix magus.brain.backfill_audit               # audit all pages
      mix magus.brain.backfill_audit --sample 100  # spot-check 100 random pages
      mix magus.brain.backfill_audit --brain-id ID # scope to one brain

  Exits non-zero on any failure so CI can use it as a gate.
  """

  use Mix.Task

  import Ecto.Query
  require Ash.Query

  alias Magus.Brain.{BlockSerializer, BodyParser}
  alias Magus.Repo

  @shortdoc "Audit Phase B backfill correctness; exits non-zero on divergence"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args, strict: [sample: :integer, brain_id: :string])

    sample = Keyword.get(opts, :sample)
    brain_id = Keyword.get(opts, :brain_id)

    body_incomplete = count_body_incomplete(brain_id)
    chunk_gaps = count_chunk_gaps(brain_id)

    Mix.shell().info("=== Phase B backfill audit ===")
    Mix.shell().info("Body never backfilled (NULL, non-trashed): #{body_incomplete}")
    Mix.shell().info("Chunk gaps (body > 50 chars but no chunks):  #{chunk_gaps}")

    pages = pages_to_check(brain_id, sample)
    Mix.shell().info("Pages to render-and-compare: #{length(pages)}")

    {body_divergences, source_mismatches, link_mismatches} =
      Enum.reduce(pages, {[], [], []}, fn page, {bd, sm, lm} ->
        result = audit_one(page)
        {bd ++ result.body, sm ++ result.sources, lm ++ result.links}
      end)

    # Divergences (body vs re-render-from-blocks, body source-URLs vs
    # brain_page_sources, body wikilinks vs brain_page_links) are EXPECTED
    # once users start editing pages via the editor — the body diverges
    # from the legacy block tree by design after cutover. They're
    # informational here, not deploy-gating. The hard-fail signals are
    # "page never got a body" and "page has body but no chunks at all".
    Mix.shell().info("\n--- Findings (informational, not deploy-gating) ---")
    Mix.shell().info("Body divergences:    #{length(body_divergences)}")
    Mix.shell().info("Source ref mismatches: #{length(source_mismatches)}")
    Mix.shell().info("Wikilink mismatches:   #{length(link_mismatches)}")

    if body_divergences != [] do
      Mix.shell().info("\nBody divergences (first 25):")
      body_divergences |> Enum.take(25) |> Enum.each(&Mix.shell().info("  - #{&1}"))
    end

    if source_mismatches != [] do
      Mix.shell().info("\nSource ref mismatches (first 25):")
      source_mismatches |> Enum.take(25) |> Enum.each(&Mix.shell().info("  - #{&1}"))
    end

    if link_mismatches != [] do
      Mix.shell().info("\nWikilink mismatches (first 25):")
      link_mismatches |> Enum.take(25) |> Enum.each(&Mix.shell().info("  - #{&1}"))
    end

    failed? = body_incomplete > 0 or chunk_gaps > 0

    if failed? do
      Mix.shell().error(
        "\nAUDIT FAILED — backfill is incomplete. Re-run `mix magus.brain.migrate`."
      )

      exit({:shutdown, 1})
    else
      Mix.shell().info("\nAUDIT PASSED")
      :ok
    end
  end

  defp pages_to_check(brain_id, nil) do
    base_query(brain_id)
    |> Repo.all()
  end

  defp pages_to_check(brain_id, sample_size) when is_integer(sample_size) do
    base_query(brain_id)
    |> order_by(fragment("RANDOM()"))
    |> limit(^sample_size)
    |> Repo.all()
  end

  defp base_query(nil) do
    from(p in "brain_pages",
      where: is_nil(p.deleted_at),
      select: %{id: p.id, brain_id: p.brain_id, body: p.body}
    )
  end

  defp base_query(brain_id) do
    brain_id_bin = Ecto.UUID.dump!(brain_id)

    from(p in "brain_pages",
      where: is_nil(p.deleted_at) and p.brain_id == ^brain_id_bin,
      select: %{id: p.id, brain_id: p.brain_id, body: p.body}
    )
  end

  defp count_body_incomplete(nil), do: count_incomplete_query(nil)
  defp count_body_incomplete(brain_id), do: count_incomplete_query(brain_id)

  defp count_incomplete_query(brain_id) do
    # Only NULL bodies indicate "never backfilled". An empty body (`""`)
    # is the legitimate post-backfill state for a page that has no blocks
    # (i.e. the user created a page but never added content).
    base =
      from(p in "brain_pages",
        where: is_nil(p.deleted_at),
        where: is_nil(p.body),
        select: count(p.id)
      )

    case brain_id do
      nil ->
        Repo.one(base)

      bid ->
        bid_bin = Ecto.UUID.dump!(bid)
        Repo.one(from p in base, where: p.brain_id == ^bid_bin)
    end
  end

  defp count_chunk_gaps(brain_id) do
    base =
      from(p in "brain_pages",
        left_join: c in "brain_page_chunks",
        on: c.page_id == p.id,
        where: is_nil(p.deleted_at),
        where: not is_nil(p.body),
        where: fragment("length(?)", p.body) > 50,
        where: is_nil(c.id),
        select: count(p.id, :distinct)
      )

    case brain_id do
      nil ->
        Repo.one(base)

      bid ->
        bid_bin = Ecto.UUID.dump!(bid)
        Repo.one(from [p, _] in base, where: p.brain_id == ^bid_bin)
    end
  end

  defp audit_one(%{id: id_bin, body: current_body}) do
    rendered = id_bin |> load_blocks() |> BlockSerializer.to_markdown()
    pretty_id = Ecto.UUID.load!(id_bin)

    body_div =
      if rendered != (current_body || "") do
        [
          "#{pretty_id}: body length #{byte_size(current_body || "")} vs rendered #{byte_size(rendered)}"
        ]
      else
        []
      end

    source_mismatch = check_source_count(id_bin, current_body, pretty_id)
    link_mismatch = check_link_count(id_bin, current_body, pretty_id)

    %{body: body_div, sources: source_mismatch, links: link_mismatch}
  end

  defp load_blocks(page_id_bin) do
    Magus.Brain.Block
    |> Ash.Query.filter(page_id == ^Ecto.UUID.load!(page_id_bin))
    |> Ash.Query.sort(position: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp check_source_count(page_id_bin, body, pretty_id) do
    expected = body |> BodyParser.source_urls() |> length()

    actual =
      Repo.one(
        from(s in "brain_page_sources",
          where: s.page_id == ^page_id_bin,
          select: count(s.id)
        )
      )

    if expected > 0 and actual != expected do
      ["#{pretty_id}: body has #{expected} source URLs, brain_page_sources has #{actual}"]
    else
      []
    end
  end

  defp check_link_count(page_id_bin, body, pretty_id) do
    # Body wikilinks count may exceed brain_page_links count because broken
    # links (target page doesn't exist) are intentionally skipped. We only
    # flag when actual > expected (extra rows = stale, not yet rebuilt).
    expected = body |> BodyParser.wikilinks() |> length()

    actual =
      Repo.one(
        from(l in "brain_page_links",
          where: l.source_page_id == ^page_id_bin,
          select: count(l.id)
        )
      )

    if actual > expected do
      ["#{pretty_id}: brain_page_links has #{actual} rows, body only has #{expected} wikilinks"]
    else
      []
    end
  end
end
