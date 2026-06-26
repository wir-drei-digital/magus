defmodule Magus.Brain.Page.Validations.MatchesLockVersion do
  @moduledoc """
  Validates that the `:base_version` argument to `Page.update_body`
  matches the current `lock_version` of the page being updated.

  Implemented as an `Ash.Resource.Change` with a `before_action` hook
  (rather than a plain `Ash.Resource.Validation`) so it can `SELECT ...
  FOR UPDATE` the row inside the transaction. Without the FOR UPDATE
  lock the check would race the actual write — two concurrent saves
  with the same `base_version` could both pass the validation, and the
  loser would surface as a bare `Ash.Error.Changes.StaleRecord` (from
  the data-layer's `WHERE lock_version = ?` filter) instead of our
  structured `VersionConflict`.

  The mismatch error carries the current body, version, last-modified
  timestamp, and `conflicting_actor_id` (the contributor of the most
  recent save). The editor LiveView pattern-matches on it to render the
  LWW recovery toast without needing a second DB round-trip.

  Mirrors `Magus.Brain.Block.Validations.LockVersion`, but returns a
  richer error (the block-side returns a bare `StaleRecord`).
  """

  use Ash.Resource.Change

  alias Magus.Brain.Page.Errors.VersionConflict
  alias Magus.Repo

  import Ecto.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      expected = Ash.Changeset.get_argument(cs, :base_version)
      page_id = cs.data.id
      page_id_bin = Ecto.UUID.dump!(page_id)

      current_row =
        Repo.one(
          from(p in "brain_pages",
            where: p.id == ^page_id_bin,
            select: %{
              body: p.body,
              lock_version: p.lock_version,
              updated_at: p.updated_at,
              contributor_id: p.contributor_id
            },
            lock: "FOR UPDATE"
          )
        )

      case current_row do
        nil ->
          # Page disappeared between read and write (e.g. soft-deleted). Let
          # Ash surface a not-found error from its own path; nothing to do.
          cs

        %{lock_version: current} when current == expected ->
          cs

        %{
          lock_version: current,
          body: body,
          updated_at: updated_at,
          contributor_id: contributor_id
        } ->
          Ash.Changeset.add_error(
            cs,
            VersionConflict.exception(
              base_version: expected,
              current_body: body,
              current_version: current,
              current_modified_at: updated_at,
              conflicting_actor_id: load_uuid(contributor_id)
            )
          )
      end
    end)
  end

  defp load_uuid(nil), do: nil
  defp load_uuid(<<_::128>> = bin), do: Ecto.UUID.load!(bin)
  defp load_uuid(s) when is_binary(s), do: s
end
