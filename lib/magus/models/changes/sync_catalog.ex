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
      # Owned (BYOK) rows never enter the catalog (see CatalogSync.build_custom),
      # so a reload for them is pure waste; skip it. Map.get returns nil for
      # global rows and for resources without the field, preserving today's
      # behavior for every global write.
      with {:ok, record} <- result,
           true <- is_nil(Map.get(record, :owner_user_id)) do
        Magus.Models.CatalogSync.request_reload()
      end

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
