defmodule Magus.Workbench.TabSession.Changes.CloseTab do
  @moduledoc """
  Removes a tab. If the closed tab was active, shifts active to the right
  neighbor; if the closed tab was the last, shifts to the left neighbor;
  if no tabs remain, sets active_tab_id to nil.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _ctx) do
    tab_id = Ash.Changeset.get_argument(changeset, :tab_id)
    tabs = Ash.Changeset.get_attribute(changeset, :tabs) || []
    current_active = Ash.Changeset.get_attribute(changeset, :active_tab_id)

    index = Enum.find_index(tabs, fn tab -> tab["id"] == tab_id end)

    case index do
      nil ->
        changeset

      idx ->
        remaining = List.delete_at(tabs, idx)

        new_active =
          cond do
            current_active != tab_id -> current_active
            remaining == [] -> nil
            idx < length(remaining) -> Enum.at(remaining, idx)["id"]
            true -> Enum.at(remaining, idx - 1)["id"]
          end

        changeset
        |> Ash.Changeset.change_attribute(:tabs, remaining)
        |> Ash.Changeset.change_attribute(:active_tab_id, new_active)
    end
  end
end
