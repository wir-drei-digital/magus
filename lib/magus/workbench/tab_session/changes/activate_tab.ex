defmodule Magus.Workbench.TabSession.Changes.ActivateTab do
  @moduledoc """
  Sets active_tab_id. Fails if no tab with that id is open.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _ctx) do
    tab_id = Ash.Changeset.get_argument(changeset, :tab_id)
    tabs = Ash.Changeset.get_attribute(changeset, :tabs) || []

    if Enum.any?(tabs, fn tab -> tab["id"] == tab_id end) do
      Ash.Changeset.change_attribute(changeset, :active_tab_id, tab_id)
    else
      Ash.Changeset.add_error(changeset,
        field: :tab_id,
        message: "no open tab with id #{inspect(tab_id)}"
      )
    end
  end
end
