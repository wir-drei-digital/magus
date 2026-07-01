defmodule Magus.Organizations.Organization.Changes.CreateOwnerMember do
  @moduledoc "After creating an org, create its owner member (the actor)."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn _changeset, org ->
      Magus.Organizations.OrganizationMember
      |> Ash.Changeset.for_create(:create_owner, %{
        organization_id: org.id,
        user_id: context.actor.id,
        invite_email: context.actor.email
      })
      |> Ash.create!(authorize?: false)

      {:ok, org}
    end)
  end
end
