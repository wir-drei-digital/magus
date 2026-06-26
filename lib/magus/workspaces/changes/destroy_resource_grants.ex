defmodule Magus.Workspaces.Changes.DestroyResourceGrants do
  @moduledoc """
  `after_action` change that deletes all ResourceAccess rows for the destroyed
  resource.

  Use on destroy/soft_delete actions:

      change {Magus.Workspaces.Changes.DestroyResourceGrants, resource_type: :folder}
  """

  use Ash.Resource.Change

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def change(changeset, opts, _context) do
    resource_type = Keyword.fetch!(opts, :resource_type)

    Ash.Changeset.after_action(changeset, fn _cs, record ->
      import Ash.Query

      Magus.Workspaces.ResourceAccess
      |> for_read(:read)
      |> filter(resource_type == ^resource_type and resource_id == ^record.id)
      |> Ash.bulk_destroy!(:revoke, %{}, authorize?: false, return_errors?: true)

      {:ok, record}
    end)
  end
end
