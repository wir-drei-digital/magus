defmodule Magus.Workspaces.WorkspaceMember.Changes.TransferOwnership do
  @moduledoc """
  Atomic ownership transfer.

  The target is promoted to `:admin` as part of the main update. In
  `after_action` (running inside the same transaction), the acting user's
  admin membership is demoted to `:member`. The demote has to run AFTER the
  main write because `NotLastAdmin` counts active admins in the DB, and the
  target must already be an admin for the demote to pass validation.

  If the demote fails for any reason, we return `{:error, error}` which Ash
  propagates as a transaction rollback, undoing the promotion.

  The action declares `transaction? true` explicitly so this ordering is not
  silently broken by future refactors.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, context) do
    actor = context.actor
    target = changeset.data

    cond do
      is_nil(actor) ->
        Ash.Changeset.add_error(changeset, field: :base, message: "Authentication required")

      target.status != :active or target.is_active != true ->
        Ash.Changeset.add_error(changeset,
          field: :base,
          message: "Cannot transfer ownership to an inactive member"
        )

      target.user_id == actor.id ->
        Ash.Changeset.add_error(changeset,
          field: :base,
          message: "You are already an admin"
        )

      true ->
        changeset
        |> Ash.Changeset.change_attribute(:role, :admin)
        |> Ash.Changeset.after_action(fn _changeset, updated_target ->
          case demote_actor(updated_target.workspace_id, actor.id) do
            :ok ->
              Magus.Workspaces.WorkspaceMember.Changes.EmitMembershipNotification.emit(
                :workspace_ownership_transferred,
                updated_target
              )

              {:ok, updated_target}

            {:error, error} ->
              {:error, error}
          end
        end)
    end
  end

  defp demote_actor(workspace_id, actor_user_id) do
    Magus.Workspaces.WorkspaceMember
    |> Ash.Query.filter(
      workspace_id == ^workspace_id and user_id == ^actor_user_id and role == :admin
    )
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} ->
        :ok

      {:ok, actor_member} ->
        actor_member
        |> Ash.Changeset.for_update(:change_role, %{role: :member}, authorize?: false)
        |> Ash.update()
        |> case do
          {:ok, _} -> :ok
          {:error, error} -> {:error, error}
        end

      {:error, error} ->
        {:error, error}
    end
  end
end
