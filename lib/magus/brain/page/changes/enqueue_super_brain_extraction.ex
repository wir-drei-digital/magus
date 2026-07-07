defmodule Magus.Brain.Page.Changes.EnqueueSuperBrainExtraction do
  @moduledoc """
  After-action change on `Magus.Brain.Page.:update_body`. Enqueues two
  Super Brain workers so a saved body syncs into its brain's Layer-1 graph:

    * `Magus.SuperBrain.Workers.ExtractBrainPage` — LLM extraction of the
      page body into entities/edges.
    * `Magus.SuperBrain.Workers.IngestBrainLinks` — materializes the page's
      `[[wikilinks]]` (from `brain_page_links`) into `:instruction`-tier
      `:mentions` edges. Enqueued on every save (not just when links change)
      so link *removals* sync too; the worker's own fingerprint gate skips
      redundant work when the resolved link set is unchanged.

  Skips both enqueues for `:template` pages: templates are reusable
  starting points, not knowledge, so they never enter the Super Brain graph.

  Uses `Oban.insert/1` so an enqueue failure cannot roll back the body write.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, page ->
      if Magus.SuperBrain.enabled?() and page.kind != :template do
        %{"resource_id" => page.id}
        |> Magus.SuperBrain.Workers.ExtractBrainPage.new()
        |> Oban.insert()

        %{"page_id" => page.id}
        |> Magus.SuperBrain.Workers.IngestBrainLinks.new()
        |> Oban.insert()
      end

      {:ok, page}
    end)
  end
end
