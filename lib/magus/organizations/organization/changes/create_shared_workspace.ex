defmodule Magus.Organizations.Organization.Changes.CreateSharedWorkspace do
  @moduledoc """
  After creating an org, create one shared workspace owned by the org. The
  workspace's own :create bootstraps the creator as its admin member.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, org ->
      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "#{org.name} Team", slug: "#{org.slug}-team"},
          actor: context.actor
        )

      workspace
      |> Ash.Changeset.for_update(:set_organization, %{organization_id: org.id},
        authorize?: false
      )
      |> Ash.update!()

      {:ok, org}
    end)
  end
end
