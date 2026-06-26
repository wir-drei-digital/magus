defmodule Magus.Brain.Page.Changes.DestroyDescendantsFirst do
  @moduledoc """
  Hard-destroys the immediate children of the page being destroyed
  before the parent's destroy runs, so each child passes through
  `UnlinkCompanions` and `BroadcastBrainEvent`. Without this, the
  parent destroy would trigger the Postgres `on_delete: :delete` FK
  cascade and remove descendant rows at the database layer, silently
  bypassing the Ash action lifecycle.

  Only direct children are walked here — each child's own destroy
  recursively walks its descendants via this same change, so the whole
  subtree gets the Ash lifecycle from leaves upward.

  Children are read via `:read_including_trashed` so the walk works
  whether the parent was reached by user "Empty trash", the 30-day
  cleanup cron, or a direct hard-destroy.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      children =
        Magus.Brain.Page
        |> Ash.Query.for_read(:read_including_trashed)
        |> Ash.Query.filter(parent_page_id == ^cs.data.id)
        |> Ash.read!(authorize?: false)

      Enum.each(children, fn child ->
        Ash.destroy!(child, authorize?: false)
      end)

      cs
    end)
  end
end
