defmodule Magus.Workspaces.WorkspaceMember.Validations.NotLastAdmin do
  @moduledoc """
  Validates that deactivating a member does not remove the last active admin
  from the workspace.
  """

  use Ash.Resource.Validation

  require Ash.Query

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    member = changeset.data
    workspace_id = member.workspace_id
    role = member.role
    action_name = changeset.action && changeset.action.name

    if role == :admin do
      check_other_admins(workspace_id, member.id, action_name)
    else
      :ok
    end
  end

  defp check_other_admins(workspace_id, member_id, action_name) do
    other_active_admins =
      Magus.Workspaces.WorkspaceMember
      |> Ash.Query.filter(
        workspace_id == ^workspace_id and
          role == :admin and
          is_active == true and
          id != ^member_id
      )
      |> Ash.count!(authorize?: false)

    if other_active_admins == 0 do
      {:error, field: :role, message: message_for(action_name)}
    else
      :ok
    end
  end

  defp message_for(:change_role),
    do: "Cannot demote the last admin. Transfer ownership first."

  defp message_for(_), do: "Cannot remove the last admin of the workspace."
end
