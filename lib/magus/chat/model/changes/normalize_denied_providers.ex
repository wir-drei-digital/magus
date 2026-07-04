defmodule Magus.Chat.Model.Changes.NormalizeDeniedProviders do
  @moduledoc """
  Normalizes the `denied_providers` list on create/update.

  The admin form renders a hidden sentinel (`denied_providers[]=""`) so an
  all-unchecked submit still sends the key and clears the list. That sentinel
  yields a blank `""` element, which must not persist. This change strips blank
  entries and de-duplicates, so `[""]` becomes `[]` and `["deepseek", ""]`
  becomes `["deepseek"]`. It only touches `denied_providers`.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :denied_providers) do
      normalized =
        changeset
        |> Ash.Changeset.get_attribute(:denied_providers)
        |> normalize()

      Ash.Changeset.change_attribute(changeset, :denied_providers, normalized)
    else
      changeset
    end
  end

  defp normalize(list) when is_list(list) do
    list
    |> Enum.map(fn value -> value |> to_string() |> String.trim() end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize(_), do: []
end
