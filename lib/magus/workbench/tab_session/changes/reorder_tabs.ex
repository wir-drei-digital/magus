defmodule Magus.Workbench.TabSession.Changes.ReorderTabs do
  @moduledoc """
  Reorders the `tabs` list to match the provided list of tab ids exactly.
  The provided ids must be the full current set — no additions or removals.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _ctx) do
    order = Ash.Changeset.get_argument(changeset, :order)
    tabs = Ash.Changeset.get_attribute(changeset, :tabs) || []

    current_ids = tabs |> Enum.map(& &1["id"]) |> MapSet.new()
    requested = MapSet.new(order)

    if current_ids == requested and length(order) == length(tabs) do
      indexed = Map.new(tabs, fn tab -> {tab["id"], tab} end)
      new_tabs = Enum.map(order, fn id -> Map.fetch!(indexed, id) end)
      Ash.Changeset.change_attribute(changeset, :tabs, new_tabs)
    else
      Ash.Changeset.add_error(changeset,
        field: :order,
        message: "order must contain exactly the current tab ids"
      )
    end
  end
end
