defmodule Magus.Chat.Message.Changes.DeleteAttachments do
  @moduledoc """
  Deletes attachment files from storage when a message is destroyed.
  """
  use Ash.Resource.Change
  require Logger

  alias Magus.Files.Storage

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      attachments = changeset.data.attachments || []

      Enum.each(attachments, fn attachment ->
        delete_attachment(attachment)
      end)

      changeset
    end)
  end

  defp delete_attachment(%{"url" => url}) when is_binary(url) do
    # Extract relative path from URL
    # URLs are in format: /uploads/files/{user_id}/{file_id}.ext
    case extract_relative_path(url) do
      {:ok, relative_path} ->
        case Storage.delete(relative_path) do
          :ok ->
            Logger.info("Deleted attachment file: #{relative_path}")

          {:error, reason} ->
            Logger.warning("Failed to delete attachment #{relative_path}: #{inspect(reason)}")
        end

      :error ->
        Logger.debug("Skipping attachment deletion for non-storage URL: #{url}")
    end
  end

  defp delete_attachment(_), do: :ok

  defp extract_relative_path(url) do
    # Match URLs like /uploads/files/user_id/file_id.ext
    case Regex.run(~r{^/uploads/files/(.+)$}, url) do
      [_, relative_path] -> {:ok, relative_path}
      nil -> :error
    end
  end
end
