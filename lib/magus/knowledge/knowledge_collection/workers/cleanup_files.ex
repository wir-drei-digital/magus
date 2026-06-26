defmodule Magus.Knowledge.KnowledgeCollection.Workers.CleanupFiles do
  @moduledoc """
  Oban worker that deletes files from a destroyed knowledge collection.

  Receives file IDs captured before the collection was deleted. Each file
  is destroyed via the standard File destroy action, which handles chunk
  deletion, storage removal, and storage usage decrement.

  Processes files in batches to avoid long-running transactions.
  """

  use Oban.Worker, queue: :knowledge_sync, max_attempts: 3

  require Logger

  @batch_size 50

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"file_ids" => file_ids}}) do
    total = length(file_ids)
    Logger.info("CleanupFiles: deleting #{total} files")

    deleted =
      file_ids
      |> Enum.chunk_every(@batch_size)
      |> Enum.reduce(0, fn batch, acc ->
        count = delete_batch(batch)
        acc + count
      end)

    Logger.info("CleanupFiles: deleted #{deleted}/#{total} files")
    :ok
  end

  defp delete_batch(file_ids) do
    file_ids
    |> Enum.reduce(0, fn file_id, count ->
      case Ash.get(Magus.Files.File, file_id, authorize?: false) do
        {:ok, file} ->
          case Ash.destroy(file, authorize?: false) do
            :ok ->
              count + 1

            {:error, reason} ->
              Logger.warning("CleanupFiles: failed to delete file #{file_id}: #{inspect(reason)}")
              count
          end

        {:error, _} ->
          # File already deleted or doesn't exist
          count
      end
    end)
  end
end
