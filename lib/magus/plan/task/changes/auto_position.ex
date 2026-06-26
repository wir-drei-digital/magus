defmodule Magus.Plan.Task.Changes.AutoPosition do
  @moduledoc """
  Auto-sets position to max(position) + 1 within scope (same conversation_id + parent_id).

  Only runs if position is nil on create.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    if changeset.action.type == :create do
      Ash.Changeset.before_action(changeset, fn changeset ->
        current_position = Ash.Changeset.get_attribute(changeset, :position)

        if is_nil(current_position) do
          conversation_id = Ash.Changeset.get_attribute(changeset, :conversation_id)
          parent_id = Ash.Changeset.get_attribute(changeset, :parent_id)

          max_position = get_max_position(conversation_id, parent_id)
          Ash.Changeset.force_change_attribute(changeset, :position, max_position + 1)
        else
          changeset
        end
      end)
    else
      changeset
    end
  end

  defp get_max_position(conversation_id, parent_id) do
    query =
      Magus.Plan.Task
      |> Ash.Query.filter(conversation_id == ^conversation_id)

    query =
      if is_nil(parent_id) do
        Ash.Query.filter(query, is_nil(parent_id))
      else
        Ash.Query.filter(query, parent_id == ^parent_id)
      end

    case Ash.read(query, authorize?: false) do
      {:ok, tasks} ->
        tasks
        |> Enum.map(& &1.position)
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> 0
          positions -> Enum.max(positions)
        end

      {:error, _} ->
        0
    end
  end
end
