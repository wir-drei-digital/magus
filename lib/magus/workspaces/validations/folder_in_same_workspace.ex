defmodule Magus.Workspaces.Validations.FolderInSameWorkspace do
  @moduledoc """
  Validates that a record's `folder_id` references a Folder in the same
  workspace as the record itself. Skipped when folder_id is nil.
  """
  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    folder_id = Ash.Changeset.get_attribute(changeset, :folder_id)
    workspace_id = Ash.Changeset.get_attribute(changeset, :workspace_id)

    case folder_id do
      nil ->
        :ok

      id ->
        case Ash.get(Magus.Chat.Folder, id, authorize?: false) do
          {:ok, folder} ->
            if folder.workspace_id == workspace_id do
              :ok
            else
              {:error,
               field: :folder_id, message: "folder must be in the same workspace as the record"}
            end

          _ ->
            {:error, field: :folder_id, message: "folder not found"}
        end
    end
  end
end
