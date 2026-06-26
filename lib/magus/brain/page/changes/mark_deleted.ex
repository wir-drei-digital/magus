defmodule Magus.Brain.Page.Changes.MarkDeleted do
  @moduledoc """
  Sets `:deleted_at` to the current UTC timestamp. Idempotent: if the
  page is already trashed, the existing timestamp is preserved (so
  double-firing the action — e.g. UI double-click or agent retry —
  doesn't drift the stamp). Sub-pages are NOT cascade-stamped; they
  become invisible to read actions by virtue of the recursive
  ancestor-trashed filter on every read.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if is_nil(changeset.data.deleted_at) do
      Ash.Changeset.force_change_attribute(changeset, :deleted_at, DateTime.utc_now())
    else
      changeset
    end
  end
end
