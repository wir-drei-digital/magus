defmodule Mix.Tasks.Magus.Brain.Migrate do
  @moduledoc """
  One-shot migration from the legacy block-based brain schema to the
  markdown-as-storage schema. Runs every Phase B backfill step in order,
  draining each until it reports zero pending pages, then exits.

  Steps (in dependency order):

    1. `BackfillPageBody`     — render blocks → `brain_pages.body`
    2. `ParseFrontmatter`     — extract YAML frontmatter from body
    3. `BackfillSources`      — promote `:source` blocks to `brain_sources`
    4. `BackfillPageChunks`   — chunk body into `brain_page_chunks`
    5. `BackfillSourceChunks` — chunk source content into `brain_source_chunks`
    6. `RebuildPageLinks`     — parse `[[wikilinks]]` from body
    7. `RebuildPageSources`   — parse source refs from body
    8. `RebuildPageTags`      — parse tags from body

  Each step is idempotent and uses sentinel/EXISTS predicates to skip
  pages it has already touched, so re-running does no harm.

  Embeddings are NOT generated here. Chunk rows are inserted with
  `embedding: nil`; the standing `generate_embedding` triggers on
  `Magus.Brain.PageChunk` / `Magus.Brain.SourceChunk` fill them in
  asynchronously at whatever rate the embedding provider permits.

  After this task exits, pair with `mix magus.brain.backfill_audit` to
  verify zero divergences before declaring the migration complete.
  """

  use Mix.Task

  alias Magus.Brain.Migrations

  @shortdoc "Migrate brain_blocks → brain_pages.body (one-shot)"

  @steps [
    {Migrations.BackfillPageBody, "page bodies"},
    {Migrations.ParseFrontmatter, "frontmatter"},
    {Migrations.BackfillSources, "sources"},
    {Migrations.BackfillPageChunks, "page chunks"},
    {Migrations.BackfillSourceChunks, "source chunks"},
    {Migrations.RebuildPageLinks, "page links"},
    {Migrations.RebuildPageSources, "page sources"},
    {Migrations.RebuildPageTags, "page tags"}
  ]

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    Mix.shell().info("=== brain migration ===")

    Enum.each(@steps, fn {worker, label} ->
      Mix.shell().info("→ #{label}")
      total = drain(worker, 0)
      Mix.shell().info("  #{total} processed")
    end)

    Mix.shell().info("\nDone. Run `mix magus.brain.backfill_audit` to verify.")
    :ok
  end

  defp drain(worker, acc) do
    case worker.run_batch() do
      {:ok, 0} -> acc
      {:ok, n} -> drain(worker, acc + n)
    end
  end
end
