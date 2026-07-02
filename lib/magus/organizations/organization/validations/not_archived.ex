defmodule Magus.Organizations.Organization.Validations.NotArchived do
  @moduledoc """
  Rejects a change when its organization is archived (`archived_at` set).

  Used on the Organization `:update` / `:archive` actions (the record itself is
  the changeset data) and on the OrganizationMember `:invite` action (the org is
  loaded from the `organization_id` argument/attribute). Archived orgs are
  read-only history: no renames, no double-archive, no new invites.
  """
  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    case resolve_org(changeset) do
      {%{archived_at: %DateTime{}}, field} ->
        {:error, field: field, message: "organization is archived"}

      _ ->
        :ok
    end
  end

  # The Organization record IS the changeset data; check its persisted archived_at.
  defp resolve_org(%{resource: Magus.Organizations.Organization} = changeset),
    do: {changeset.data, :archived_at}

  # For OrganizationMember (invite), resolve the org via organization_id.
  defp resolve_org(changeset) do
    org_id =
      Ash.Changeset.get_argument(changeset, :organization_id) ||
        Ash.Changeset.get_attribute(changeset, :organization_id) ||
        (changeset.data && Map.get(changeset.data, :organization_id))

    case org_id && Ash.get(Magus.Organizations.Organization, org_id, authorize?: false) do
      {:ok, org} -> {org, :organization_id}
      _ -> {nil, :organization_id}
    end
  end
end
