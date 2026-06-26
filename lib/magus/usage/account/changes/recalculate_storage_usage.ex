defmodule Magus.Usage.Account.Changes.RecalculateStorageUsage do
  @moduledoc """
  Recalculates the storage_usage_bytes by summing all file sizes for the user.

  Used to fix storage drift when the cached counter gets out of sync with reality
  (e.g., server crash between file delete and counter decrement).
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    user_id = changeset.data.user_id

    real_usage =
      Magus.Files.File
      |> Ash.Query.filter(user_id == ^user_id)
      |> Ash.sum!(:file_size, authorize?: false) || 0

    Ash.Changeset.force_change_attribute(changeset, :storage_usage_bytes, real_usage)
  end
end
