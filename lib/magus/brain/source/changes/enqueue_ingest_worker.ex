defmodule Magus.Brain.Source.Changes.EnqueueIngestWorker do
  @moduledoc """
  After-action change wired into `Magus.Brain.Source.:create` and
  `:from_legacy_block`. Enqueues `Magus.Brain.Source.IngestWorker` for
  the new row when its `ingest_status` is `:pending`.

  Legacy backfill rows usually arrive with status `:ingested` or
  `:failed` (preserving the prior block's recorded state), so they skip
  enqueueing here. Any row whose state is genuinely `:pending` — whether
  from C1's `update_body_derived_state` upsert or from a legacy block
  that never finished ingesting — gets a fresh worker.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, source ->
      if source.ingest_status == :pending do
        %{"source_id" => source.id}
        |> Magus.Brain.Source.IngestWorker.new()
        |> Oban.insert!()
      end

      {:ok, source}
    end)
  end
end
