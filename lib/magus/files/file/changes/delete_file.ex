defmodule Magus.Files.File.Changes.DeleteFile do
  @moduledoc """
  Deletes chunks and the file from storage when a file is destroyed.
  """
  use Ash.Resource.Change
  require Ash.Query
  require Logger

  alias Magus.Files.Storage

  @impl true
  def change(changeset, _opts, _context) do
    # Snapshot fields for after_action since changeset.data won't survive destroy
    file_snapshot = %{
      user_id: changeset.data.user_id,
      workspace_id: changeset.data.workspace_id,
      file_size: changeset.data.file_size
    }

    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      file_id = changeset.data.id
      file_path = changeset.data.file_path
      storage_backend = changeset.data.storage_backend

      # Delete all chunks for this file
      Magus.Files.Chunk
      |> Ash.Query.filter(file_id == ^file_id)
      |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false, strategy: :atomic)

      # Delete the file from storage using the appropriate backend
      if file_path do
        backend = parse_backend(storage_backend)

        case Storage.delete(file_path, backend: backend) do
          :ok ->
            Logger.info("Deleted file from #{backend}: #{file_path}")

          {:error, reason} ->
            Logger.warning(
              "Failed to delete file #{file_path} from #{backend}: #{inspect(reason)}"
            )
        end
      end

      changeset
    end)
    |> Ash.Changeset.after_action(fn _changeset, result ->
      Magus.Files.StorageTracking.track_destroy(file_snapshot)
      {:ok, result}
    end)
  end

  defp parse_backend("s3"), do: :s3
  defp parse_backend("local"), do: :local
  defp parse_backend(_), do: :local
end
