defmodule Magus.Workspaces.Validations.ParentInSameWorkspace do
  @moduledoc """
  Validates that a hierarchical resource's `parent_id` refers to a record
  in the same workspace as the new/updated record.

  Options:
    * `:parent_field` (default `:parent_id`)
    * `:workspace_field` (default `:workspace_id`)
    * `:parent_resource` (required) the Ash resource module to fetch the parent from.
  """

  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, opts, _context) do
    parent_field = Keyword.get(opts, :parent_field, :parent_id)
    workspace_field = Keyword.get(opts, :workspace_field, :workspace_id)
    parent_resource = Keyword.fetch!(opts, :parent_resource)

    parent_id = Ash.Changeset.get_attribute(changeset, parent_field)
    workspace_id = Ash.Changeset.get_attribute(changeset, workspace_field)

    case parent_id do
      nil ->
        :ok

      id ->
        case Ash.get(parent_resource, id, authorize?: false) do
          {:ok, parent} ->
            if Map.get(parent, workspace_field) == workspace_id do
              :ok
            else
              {:error,
               field: parent_field, message: "parent must be in the same workspace as the record"}
            end

          _ ->
            {:error, field: parent_field, message: "parent not found"}
        end
    end
  end
end
