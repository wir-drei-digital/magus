defmodule Magus.Organizations.Organization.Changes.ArchiveOrganization do
  @moduledoc """
  Soft-deletes an organization. In one transaction it deactivates every active
  org workspace, offboards every active/invited membership, then stamps
  `archived_at` and renames the slug so the original slug frees up for reuse.
  After the transaction commits it fires the billing seam exactly once.

  Member offboarding uses OrganizationMember `:remove_for_archive` (no per-member
  seat-sync, no last-owner guard) so the only billing signal is the single
  `on_organization_archived/1` fired from `after_transaction`.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> stamp_archived()
    |> Ash.Changeset.before_action(&offboard(&1, context))
    |> Ash.Changeset.after_transaction(&fire_seam/2)
  end

  # Step 3: plain attribute changes on the changeset (persisted by the update).
  defp stamp_archived(changeset) do
    org = changeset.data

    changeset
    |> Ash.Changeset.force_change_attribute(:archived_at, DateTime.utc_now())
    |> Ash.Changeset.force_change_attribute(:slug, archived_slug(org))
  end

  # Steps 1-2: run in-transaction before the primary update persists.
  defp offboard(changeset, context) do
    org = changeset.data
    actor = context.actor

    deactivate_workspaces(org, actor)
    remove_members(org, actor)

    changeset
  end

  defp deactivate_workspaces(org, actor) do
    Magus.Workspaces.Workspace
    |> Ash.Query.filter(organization_id == ^org.id and is_active == true)
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn workspace ->
      # authorize?: true — the Task-1 :deactivate policy clause authorizes the
      # org owner; actor is passed for paper-trail attribution.
      workspace
      |> Ash.Changeset.for_update(:deactivate, %{}, actor: actor)
      |> Ash.update!(actor: actor)
    end)
  end

  defp remove_members(org, actor) do
    Magus.Organizations.OrganizationMember
    |> Ash.Query.filter(organization_id == ^org.id and status in [:active, :invited])
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn member ->
      member
      |> Ash.Changeset.for_update(:remove_for_archive, %{}, authorize?: false, actor: actor)
      |> Ash.update!()
    end)
  end

  # Step 4: fire the billing seam once, only on a successful commit.
  defp fire_seam(_changeset, {:ok, org} = result) do
    Magus.Organizations.SeatSync.on_organization_archived(org.id)
    result
  end

  defp fire_seam(_changeset, other), do: other

  # "<prefix>-archived-<6 hex of id>", kept within the 64-char slug cap and valid
  # against ~r/\A[a-z0-9][a-z0-9-]*[a-z0-9]\z/. Reserve room for the "-archived-"
  # marker (10 chars incl. both hyphens) plus 6 id hex chars = 16; the prefix
  # keeps the org slug's first char and the suffix ends in a hex digit, so the
  # result always satisfies the regex.
  defp archived_slug(org) do
    reserved = String.length("-archived-") + 6
    prefix = String.slice(org.slug, 0, 64 - reserved)
    "#{prefix}-archived-#{String.slice(org.id, 0, 6)}"
  end
end
