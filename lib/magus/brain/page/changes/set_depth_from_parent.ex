defmodule Magus.Brain.Page.Changes.SetDepthFromParent do
  @moduledoc """
  Sets the `:depth` attribute on a newly-created page based on its parent.

  Root pages get depth 0; sub-pages get `parent.depth + 1`. Depth is
  still tracked (breadcrumbs, sort order) even though the old nesting
  cap was removed in Phase C7 — there is no longer a maximum-depth
  rejection here.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    parent_page_id = Ash.Changeset.get_attribute(changeset, :parent_page_id)

    if parent_page_id do
      Ash.Changeset.before_action(changeset, fn changeset ->
        case Ash.get(Magus.Brain.Page, parent_page_id, authorize?: false) do
          {:ok, parent} ->
            Ash.Changeset.force_change_attribute(changeset, :depth, parent.depth + 1)

          {:error, _} ->
            Ash.Changeset.add_error(changeset,
              field: :parent_page_id,
              message: "parent page not found"
            )
        end
      end)
    else
      Ash.Changeset.force_change_attribute(changeset, :depth, 0)
    end
  end
end
