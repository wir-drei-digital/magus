defmodule Magus.Workbench.TabSession.Changes.SetCompanion do
  @moduledoc """
  Updates the companion field on a specific tab. Pass nil to clear.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _ctx) do
    tab_id = Ash.Changeset.get_argument(changeset, :tab_id)
    companion = Ash.Changeset.get_argument(changeset, :companion)
    tabs = Ash.Changeset.get_attribute(changeset, :tabs) || []

    case Enum.find_index(tabs, fn tab -> tab["id"] == tab_id end) do
      nil ->
        Ash.Changeset.add_error(changeset,
          field: :tab_id,
          message: "no open tab with id #{inspect(tab_id)}"
        )

      idx ->
        updated_tab = Map.put(Enum.at(tabs, idx), "companion", companion)
        new_tabs = List.replace_at(tabs, idx, updated_tab)
        Ash.Changeset.change_attribute(changeset, :tabs, new_tabs)
    end
  end
end
