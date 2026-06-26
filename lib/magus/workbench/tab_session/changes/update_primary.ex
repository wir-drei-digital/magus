defmodule Magus.Workbench.TabSession.Changes.UpdatePrimary do
  @moduledoc """
  Replaces a single tab's `"primary"` map identified by tab id.
  No-op if the tab id is not present.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _ctx) do
    tab_id = Ash.Changeset.get_argument(changeset, :tab_id)
    new_primary = Ash.Changeset.get_argument(changeset, :primary)
    current_tabs = Ash.Changeset.get_attribute(changeset, :tabs) || []

    updated =
      Enum.map(current_tabs, fn tab ->
        if tab["id"] == tab_id, do: Map.put(tab, "primary", new_primary), else: tab
      end)

    Ash.Changeset.change_attribute(changeset, :tabs, updated)
  end
end
