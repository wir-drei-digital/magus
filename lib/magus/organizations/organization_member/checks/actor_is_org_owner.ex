defmodule Magus.Organizations.OrganizationMember.Checks.ActorIsOrgOwner do
  @moduledoc """
  Policy check: the actor is an active owner of the organization. Reads
  organization_id from the changeset argument (create actions) or from the
  record being updated.
  """
  use Ash.Policy.SimpleCheck

  require Ash.Query

  @impl true
  def describe(_opts), do: "actor is an active owner of the organization"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    organization_id =
      Ash.Changeset.get_argument(changeset, :organization_id) ||
        Map.get(changeset.data, :organization_id)

    organization_id && active_owner?(organization_id, actor.id)
  end

  def match?(_actor, _context, _opts), do: false

  defp active_owner?(organization_id, user_id) do
    Magus.Organizations.OrganizationMember
    |> Ash.Query.filter(
      organization_id == ^organization_id and
        user_id == ^user_id and
        role == :owner and
        status == :active
    )
    |> Ash.count!(authorize?: false) > 0
  end
end
