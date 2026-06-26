defmodule Magus.Workbench.TabSession.Changes.OpenTab do
  @moduledoc """
  Appends a new tab, or activates an existing one that already holds the same
  primary resource. Sets active_tab_id to the resulting tab's id.

  Accepts an optional `:label` argument that is stored on the tab; if not
  provided, the tab has a nil label and the UI resolves it via
  `MagusWeb.Workbench.Tab.LabelResolver`.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _ctx) do
    primary = Ash.Changeset.get_argument(changeset, :primary)
    label = Ash.Changeset.get_argument(changeset, :label)
    single = Ash.Changeset.get_argument(changeset, :single) || false
    current_tabs = Ash.Changeset.get_attribute(changeset, :tabs) || []

    existing = Enum.find(current_tabs, fn tab -> tab["primary"] == primary end)

    {tabs, active_id} =
      case existing do
        nil ->
          new_tab = %{
            "id" => "tab_" <> Ecto.UUID.generate(),
            "primary" => primary,
            "companion" => nil,
            "label" => label,
            "opened_at" => DateTime.to_iso8601(DateTime.utc_now())
          }

          {current_tabs ++ [new_tab], new_tab["id"]}

        tab ->
          updated_tab =
            if label && label != tab["label"],
              do: Map.put(tab, "label", label),
              else: tab

          updated_tabs =
            Enum.map(current_tabs, fn t ->
              if t["id"] == tab["id"], do: updated_tab, else: t
            end)

          {updated_tabs, tab["id"]}
      end

    # tabs disabled: collapse to just the active tab so the shell never
    # accumulates hidden tabs (mirrors the old open_tab + replace_tabs sequence
    # in a single action / round trip).
    tabs = if single, do: Enum.filter(tabs, &(&1["id"] == active_id)), else: tabs

    changeset
    |> Ash.Changeset.change_attribute(:tabs, tabs)
    |> Ash.Changeset.change_attribute(:active_tab_id, active_id)
  end
end
