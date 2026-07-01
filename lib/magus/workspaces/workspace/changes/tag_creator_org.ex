defmodule Magus.Workspaces.Workspace.Changes.TagCreatorOrg do
  @moduledoc """
  If the creating actor is an active member of an organization, tag the new
  workspace with that org's id. Members belong to at most one org.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, workspace ->
      case actor_org_id(context.actor) do
        nil ->
          {:ok, workspace}

        org_id ->
          updated =
            workspace
            |> Ash.Changeset.for_update(:set_organization, %{organization_id: org_id},
              authorize?: false
            )
            |> Ash.update!()

          {:ok, updated}
      end
    end)
  end

  defp actor_org_id(nil), do: nil

  defp actor_org_id(actor) do
    Magus.Organizations.OrganizationMember
    |> Ash.Query.filter(user_id == ^actor.id and status == :active)
    |> Ash.Query.select([:organization_id])
    |> Ash.read!(authorize?: false)
    |> case do
      [%{organization_id: org_id} | _] -> org_id
      [] -> nil
    end
  end
end
