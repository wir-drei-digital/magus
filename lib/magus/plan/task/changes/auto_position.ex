defmodule Magus.Plan.Task.Changes.AutoPosition do
  @moduledoc """
  Auto-sets position to max(position) + 1 within the task's scope. Scope is the
  container (conversation_id OR brain_page_id) plus parent_id. Only runs when
  position is nil on create.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    if changeset.action.type == :create do
      Ash.Changeset.before_action(changeset, fn changeset ->
        if is_nil(Ash.Changeset.get_attribute(changeset, :position)) do
          conversation_id = Ash.Changeset.get_attribute(changeset, :conversation_id)
          brain_page_id = Ash.Changeset.get_attribute(changeset, :brain_page_id)
          parent_id = Ash.Changeset.get_attribute(changeset, :parent_id)

          max_position = max_position(conversation_id, brain_page_id, parent_id)
          Ash.Changeset.force_change_attribute(changeset, :position, max_position + 1)
        else
          changeset
        end
      end)
    else
      changeset
    end
  end

  defp max_position(conversation_id, brain_page_id, parent_id) do
    Magus.Plan.Task
    |> scope(conversation_id, brain_page_id)
    |> parent_scope(parent_id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.position)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> 0
      positions -> Enum.max(positions)
    end
  end

  defp scope(query, conversation_id, nil),
    do: Ash.Query.filter(query, conversation_id == ^conversation_id)

  defp scope(query, nil, brain_page_id),
    do: Ash.Query.filter(query, brain_page_id == ^brain_page_id)

  defp scope(_query, _conversation_id, _brain_page_id) do
    raise ArgumentError,
          "AutoPosition requires exactly one container (conversation_id xor brain_page_id)"
  end

  defp parent_scope(query, nil), do: Ash.Query.filter(query, is_nil(parent_id))
  defp parent_scope(query, parent_id), do: Ash.Query.filter(query, parent_id == ^parent_id)
end
