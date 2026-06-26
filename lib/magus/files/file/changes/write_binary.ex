defmodule Magus.Files.File.Changes.WriteBinary do
  @moduledoc """
  On the :replace_content action, writes the new binary to the configured
  storage backend at the file's existing path, and updates file_size on
  the row to match.
  """

  use Ash.Resource.Change

  require Logger

  alias Magus.Files.Storage

  @impl true
  def change(changeset, _opts, _ctx) do
    Ash.Changeset.before_action(changeset, fn cs ->
      binary = Ash.Changeset.get_argument(cs, :binary)
      file = cs.data

      case Storage.store(file.file_path, binary, content_type: file.mime_type) do
        {:ok, _path} ->
          Ash.Changeset.force_change_attribute(cs, :file_size, byte_size(binary))

        {:error, reason} ->
          Logger.error("WriteBinary: storage write failed: #{inspect(reason)}")
          Ash.Changeset.add_error(cs, message: "storage write failed: #{inspect(reason)}")
      end
    end)
  end
end
