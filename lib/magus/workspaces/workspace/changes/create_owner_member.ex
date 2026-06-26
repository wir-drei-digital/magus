defmodule Magus.Workspaces.Workspace.Changes.CreateOwnerMember do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, workspace ->
      Magus.Workspaces.WorkspaceMember
      |> Ash.Changeset.for_create(:create_admin, %{
        workspace_id: workspace.id,
        user_id: context.actor.id,
        invite_email: context.actor.email
      })
      |> Ash.create!(authorize?: false)

      {:ok, workspace}
    end)
  end
end
