defmodule Mix.Tasks.Magus.Brain.ForceResync do
  @moduledoc """
  Force-re-renders `brain_pages.body` from blocks for every non-trashed page,
  comparing against the live value and updating only when divergent. Also
  clears the three Phase B rebuild sentinels (`_links_built_at`,
  `_sources_built_at`, `_tags_built_at`) so the cron rebuild workers re-run
  on the next tick.

  Idempotent. Designed to be run ONCE before Phase C cutover, after the
  Phase B backfill cron has had time to bake. Pairs with
  `Magus.Brain.Releases.AssertBodyComplete` which the deploy pipeline runs
  to verify zero pages were left with `body IS NULL OR body = ''`.

  ## Usage

      mix magus.brain.force_resync               # run for all brains
      mix magus.brain.force_resync --dry-run     # report divergences without writing
      mix magus.brain.force_resync --brain-id ID # scope to one brain (debug)

  ## Output

  Prints a summary at the end via `Mix.shell()`:

      Scanned: 12,453 pages
      Re-rendered: 7 divergent
      Cleared sentinels: 11,892 pages

  Each divergence is listed (first 25) with the page id and a length-delta
  so an operator can spot-check.
  """

  use Mix.Task

  import Ecto.Query
  require Ash.Query

  alias Magus.Brain.BlockSerializer
  alias Magus.Repo

  @shortdoc "Re-render brain_pages.body from blocks and clear rebuild sentinels"

  @sentinel_keys ~w(_links_built_at _sources_built_at _tags_built_at)

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args, strict: [dry_run: :boolean, brain_id: :string])

    dry_run? = Keyword.get(opts, :dry_run, false)
    brain_id = Keyword.get(opts, :brain_id)

    pages = pages_to_check(brain_id)
    total = length(pages)

    Mix.shell().info("Scanning #{total} pages#{if dry_run?, do: " (dry run)", else: ""}")

    {rerendered, sentinels_cleared, divergences} =
      Enum.reduce(pages, {0, 0, []}, fn page, {r, s, divs} ->
        result = process_one(page, dry_run?)
        {r + result.rerendered, s + result.sentinels_cleared, divs ++ result.divergences}
      end)

    Mix.shell().info("\n=== Force-resync summary ===")
    Mix.shell().info("Scanned: #{total}")
    Mix.shell().info("Re-rendered: #{rerendered}")
    Mix.shell().info("Cleared sentinels: #{sentinels_cleared}")

    if divergences != [] do
      Mix.shell().info("\nDivergent pages (first 25):")
      divergences |> Enum.take(25) |> Enum.each(&Mix.shell().info("  - #{&1}"))
    end

    :ok
  end

  defp pages_to_check(nil) do
    Repo.all(
      from(p in "brain_pages",
        where: is_nil(p.deleted_at),
        select: %{id: p.id, body: p.body, frontmatter: p.frontmatter},
        order_by: [asc: p.inserted_at]
      )
    )
  end

  defp pages_to_check(brain_id) do
    brain_id_bin = Ecto.UUID.dump!(brain_id)

    Repo.all(
      from(p in "brain_pages",
        where: is_nil(p.deleted_at) and p.brain_id == ^brain_id_bin,
        select: %{id: p.id, body: p.body, frontmatter: p.frontmatter},
        order_by: [asc: p.inserted_at]
      )
    )
  end

  defp process_one(%{id: id, body: current_body, frontmatter: frontmatter}, dry_run?) do
    blocks = load_blocks(id)
    rendered = BlockSerializer.to_markdown(blocks)
    diverges? = rendered != (current_body || "")
    sentinels_to_clear = Map.take(frontmatter || %{}, @sentinel_keys)
    has_sentinels? = sentinels_to_clear != %{}

    cond do
      dry_run? ->
        %{
          rerendered: if(diverges?, do: 1, else: 0),
          sentinels_cleared: if(has_sentinels?, do: 1, else: 0),
          divergences: if(diverges?, do: [divergence_line(id, current_body, rendered)], else: [])
        }

      diverges? or has_sentinels? ->
        cleaned_frontmatter = Map.drop(frontmatter || %{}, @sentinel_keys)
        now = DateTime.utc_now()

        update_fields =
          if diverges?,
            do: [body: rendered, frontmatter: cleaned_frontmatter, updated_at: now],
            else: [frontmatter: cleaned_frontmatter, updated_at: now]

        {1, _} =
          from(p in "brain_pages", where: p.id == ^id)
          |> Repo.update_all(set: update_fields)

        %{
          rerendered: if(diverges?, do: 1, else: 0),
          sentinels_cleared: if(has_sentinels?, do: 1, else: 0),
          divergences: if(diverges?, do: [divergence_line(id, current_body, rendered)], else: [])
        }

      true ->
        %{rerendered: 0, sentinels_cleared: 0, divergences: []}
    end
  end

  defp divergence_line(id_bin, current, rendered) do
    "#{Ecto.UUID.load!(id_bin)} (body length #{byte_size(current || "")} → #{byte_size(rendered)})"
  end

  defp load_blocks(page_id_bin) do
    Magus.Brain.Block
    |> Ash.Query.filter(page_id == ^Ecto.UUID.load!(page_id_bin))
    |> Ash.Query.sort(position: :asc)
    |> Ash.read!(authorize?: false)
  end
end
