defmodule Magus.Brain.Source.Changes.EnqueueSuperBrainExtraction do
  @moduledoc """
  After-action change on `Magus.Brain.Source.:ingest`. When ingestion
  lands content (`ingest_status: :ingested`), enqueues
  `Magus.SuperBrain.Workers.ExtractBrainSource` so the ingested text feeds
  the brain's Layer-1 graph. Uses `Oban.insert/1` (not `!`) so an enqueue
  failure cannot roll back the ingest write.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, source ->
      if Magus.SuperBrain.enabled?() and source.ingest_status == :ingested do
        %{"resource_id" => source.id}
        |> Magus.SuperBrain.Workers.ExtractBrainSource.new()
        |> Oban.insert()
      end

      {:ok, source}
    end)
  end
end
