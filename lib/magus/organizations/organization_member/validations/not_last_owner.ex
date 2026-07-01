defmodule Magus.Organizations.OrganizationMember.Validations.NotLastOwner do
  @moduledoc """
  Prevents removing or demoting the last active owner of an organization.
  """
  use Ash.Resource.Validation

  require Ash.Query

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    member = changeset.data
    action_name = changeset.action && changeset.action.name

    if member.role == :owner do
      check_other_owners(member.organization_id, member.id, action_name)
    else
      :ok
    end
  end

  defp check_other_owners(organization_id, member_id, action_name) do
    others =
      Magus.Organizations.OrganizationMember
      |> Ash.Query.filter(
        organization_id == ^organization_id and
          role == :owner and
          status == :active and
          id != ^member_id
      )
      |> Ash.count!(authorize?: false)

    if others == 0 do
      {:error, field: :role, message: message_for(action_name)}
    else
      :ok
    end
  end

  defp message_for(:change_role), do: "Cannot demote the last owner. Transfer ownership first."
  defp message_for(_), do: "Cannot remove the last owner of the organization."
end
