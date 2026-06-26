defmodule Magus.Workspaces.Workspace.Changes.RecalculateStorageUsage do
  @moduledoc """
  Recalculates `storage_usage_bytes` for the workspace by summing all
  `file_size` values across files with this workspace_id. Used to fix drift
  after failed increments or manual data changes.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    workspace_id = changeset.data.id

    real_usage =
      Magus.Files.File
      |> Ash.Query.filter(workspace_id == ^workspace_id)
      |> Ash.sum!(:file_size, authorize?: false) || 0

    Ash.Changeset.force_change_attribute(changeset, :storage_usage_bytes, real_usage)
  end
end
