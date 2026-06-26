defmodule Magus.Plan.Task.Changes.SetCompletedBy do
  @moduledoc """
  Manages the completed_by field based on status transitions.

  - When status changes to "done", sets completed_by to "user" if actor is a User,
    or "agent" otherwise.
  - When status changes away from "done" (reopened), clears completed_by to nil.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    new_status = Ash.Changeset.get_attribute(changeset, :status)
    old_status = Map.get(changeset.data, :status)

    cond do
      new_status == :done and old_status != :done ->
        completed_by =
          case context.actor do
            %Magus.Accounts.User{} -> "user"
            _ -> "agent"
          end

        Ash.Changeset.force_change_attribute(changeset, :completed_by, completed_by)

      old_status == :done and new_status != :done and not is_nil(new_status) ->
        Ash.Changeset.force_change_attribute(changeset, :completed_by, nil)

      true ->
        changeset
    end
  end
end
