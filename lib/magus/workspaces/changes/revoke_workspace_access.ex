defmodule Magus.Workspaces.Changes.RevokeWorkspaceAccess do
  @moduledoc """
  `after_action` change that revokes the `:workspace` grant on
  `Magus.Workspaces.ResourceAccess` for the updated record. Idempotent — runs a
  bulk destroy filtered to grants for this `(resource_type, resource_id,
  workspace_id)` triple and returns `:ok` when no rows match.

  Use on `unshare_from_team`-style update actions:

      change {Magus.Workspaces.Changes.RevokeWorkspaceAccess, resource_type: :folder}
  """

  use Ash.Resource.Change

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def change(changeset, opts, _context) do
    resource_type = Keyword.fetch!(opts, :resource_type)

    Ash.Changeset.after_action(changeset, fn _cs, record ->
      require Ash.Query

      Magus.Workspaces.ResourceAccess
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(
        resource_type == ^resource_type and
          resource_id == ^record.id and
          grantee_type == :workspace and
          grantee_id == ^record.workspace_id
      )
      |> Ash.bulk_destroy!(:revoke, %{}, authorize?: false, return_errors?: true)

      {:ok, record}
    end)
  end
end
