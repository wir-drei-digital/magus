defmodule Magus.Organizations.OrganizationMember.Changes.AddToSharedWorkspace do
  @moduledoc """
  After a member accepts an org invite, add them to the org's shared workspace
  (the one auto-created at org creation, found by `organization_id`; if an org
  has more than one workspace, the earliest by `inserted_at` is the shared one).

  Idempotent: if the user is already a member of the shared workspace we skip the
  create, so replaying `:accept` never crashes and never duplicates the row. This
  is a best-effort after-action — a failure here does not fail the accept.
  """
  use Ash.Resource.Change
  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, member ->
      with true <- not is_nil(member.user_id),
           {:ok, [workspace | _]} <- shared_workspace(member.organization_id) do
        add_member(workspace.id, member.user_id, member.invite_email)
      end

      {:ok, member}
    end)
  end

  defp shared_workspace(org_id) do
    Magus.Workspaces.Workspace
    |> Ash.Query.filter(organization_id == ^org_id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read(authorize?: false)
  end

  # Check-first idempotency: avoid tripping the `unique_membership`
  # [workspace_id, user_id] index (which would poison the surrounding
  # transaction). Fall back to a rescue as a final safety net.
  defp add_member(workspace_id, user_id, invite_email) do
    if member_exists?(workspace_id, user_id) do
      :ok
    else
      Magus.Workspaces.WorkspaceMember
      |> Ash.Changeset.for_create(
        :create_member,
        %{workspace_id: workspace_id, user_id: user_id, invite_email: invite_email || ""},
        authorize?: false
      )
      |> Ash.create(authorize?: false)
    end
  rescue
    _ -> :ok
  end

  defp member_exists?(workspace_id, user_id) do
    Magus.Workspaces.WorkspaceMember
    |> Ash.Query.filter(workspace_id == ^workspace_id and user_id == ^user_id)
    |> Ash.exists?(authorize?: false)
  end
end
