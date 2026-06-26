defmodule Magus.Models.Changes.SyncCatalog do
  @moduledoc """
  Requests an async LLMDB catalog reload after a successful Provider or
  Model write commits. after_transaction so the reload reads committed data.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      # Rolled-back writes change nothing, so no reload on error results.
      if match?({:ok, _}, result), do: Magus.Models.CatalogSync.request_reload()

      result
    end)
  end

  # Only adds an after_transaction hook (runs outside the data-layer
  # statement), so the change is safe in atomic pipelines.
  @impl true
  def atomic(changeset, opts, context) do
    {:ok, change(changeset, opts, context)}
  end
end
