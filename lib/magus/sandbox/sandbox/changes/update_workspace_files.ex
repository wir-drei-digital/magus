defmodule Magus.Sandbox.Sandbox.Changes.UpdateWorkspaceFiles do
  @moduledoc """
  Updates the sandbox's workspace_files list after code execution.

  Stores the current state of files in /workspace so context can be built
  without requiring a live API call to the sandbox.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :workspace_files) do
      nil ->
        changeset

      files when is_list(files) ->
        # Normalize file entries to ensure consistent structure
        normalized =
          Enum.map(files, fn file ->
            %{
              "path" => file["path"] || file[:path] || file["name"] || file[:name],
              "size" => file["size"] || file[:size] || 0
            }
          end)
          |> Enum.reject(fn f -> is_nil(f["path"]) end)

        Ash.Changeset.force_change_attribute(changeset, :workspace_files, normalized)

      _ ->
        changeset
    end
  end
end
