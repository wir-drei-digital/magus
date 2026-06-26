defmodule Magus.Plan.Task.Changes.ValidateNesting do
  @moduledoc """
  Ensures single-level nesting for tasks.

  If parent_id is set, verifies that the parent task has no parent_id itself,
  preventing nesting deeper than one level.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      parent_id = Ash.Changeset.get_attribute(changeset, :parent_id)

      if parent_id do
        case Ash.get(Magus.Plan.Task, parent_id, authorize?: false) do
          {:ok, parent} ->
            if parent.parent_id do
              Ash.Changeset.add_error(changeset,
                field: :parent_id,
                message: "cannot nest tasks more than one level deep"
              )
            else
              changeset
            end

          {:error, _} ->
            Ash.Changeset.add_error(changeset,
              field: :parent_id,
              message: "parent task not found"
            )
        end
      else
        changeset
      end
    end)
  end
end
