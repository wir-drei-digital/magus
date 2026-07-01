defmodule Magus.Organizations.OrganizationMember.Validations.OneOrgPerUser do
  @moduledoc """
  A user may be an active member of at most one organization. Rejects a
  create/accept that would give a user active membership in a second org.
  """
  use Ash.Resource.Validation

  require Ash.Query

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, context) do
    user_id =
      Ash.Changeset.get_argument(changeset, :user_id) ||
        Ash.Changeset.get_attribute(changeset, :user_id) ||
        (context.actor && context.actor.id)

    org_id =
      Ash.Changeset.get_argument(changeset, :organization_id) ||
        Ash.Changeset.get_attribute(changeset, :organization_id) ||
        (changeset.data && Map.get(changeset.data, :organization_id))

    cond do
      is_nil(user_id) ->
        :ok

      already_active_elsewhere?(user_id, org_id) ->
        {:error, field: :user_id, message: "user already belongs to an organization"}

      true ->
        :ok
    end
  end

  defp already_active_elsewhere?(user_id, org_id) do
    query =
      Magus.Organizations.OrganizationMember
      |> Ash.Query.filter(user_id == ^user_id and status == :active)

    query =
      if org_id do
        Ash.Query.filter(query, organization_id != ^org_id)
      else
        query
      end

    Ash.count!(query, authorize?: false) > 0
  end
end
