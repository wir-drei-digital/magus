defmodule Magus.Library.Tag.Validations.ActorInWorkspace do
  @moduledoc """
  A workspace tag may only be created by an active member of that workspace.
  Personal and legacy/global tags (no workspace_id) pass through.
  """
  use Ash.Resource.Validation

  require Ash.Query

  @impl true
  def validate(changeset, _opts, %{actor: actor}) do
    case Ash.Changeset.get_attribute(changeset, :workspace_id) do
      nil ->
        :ok

      workspace_id ->
        member? =
          actor != nil and
            Magus.Workspaces.WorkspaceMember
            |> Ash.Query.filter(
              workspace_id == ^workspace_id and user_id == ^actor.id and is_active == true
            )
            |> Ash.exists?(authorize?: false)

        if member? do
          :ok
        else
          {:error, field: :workspace_id, message: "must be an active member of the workspace"}
        end
    end
  end
end
