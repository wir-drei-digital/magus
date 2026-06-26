defmodule Magus.Files.File.Changes.StoreContent do
  @moduledoc """
  Stores binary content to storage and sets up the file file_path.

  Used by the `create_from_content` action for agent-generated files.
  Handles both raw binary content and base64-encoded content.
  """
  use Ash.Resource.Change

  require Logger

  alias Magus.Files.Storage

  @impl true
  def change(changeset, _opts, _context) do
    content = Ash.Changeset.get_argument(changeset, :content)
    content_encoding = Ash.Changeset.get_argument(changeset, :content_encoding) || :binary

    case decode_content(content, content_encoding) do
      {:ok, binary_data} ->
        store_and_configure(changeset, binary_data)

      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :content,
          message: "Failed to decode: #{reason}"
        )
    end
  end

  defp decode_content(content, :binary) when is_binary(content), do: {:ok, content}

  defp decode_content(content, :base64) when is_binary(content) do
    case Base.decode64(content) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, :invalid_base64}
    end
  end

  defp decode_content(content, :data_uri) when is_binary(content) do
    case Regex.run(~r/^data:([^;]+);base64,(.+)$/s, content) do
      [_, _mime_type, base64_data] ->
        Base.decode64(base64_data)

      nil ->
        {:error, :invalid_data_uri}
    end
  end

  defp decode_content(_, _), do: {:error, :invalid_content}

  defp store_and_configure(changeset, binary_data) do
    user_id = Ash.Changeset.get_attribute(changeset, :user_id)
    mime_type = Ash.Changeset.get_attribute(changeset, :mime_type)

    # Generate file ID and file path
    file_id = Ash.UUIDv7.generate()
    extension = mime_type_to_extension(mime_type)
    filename = "#{file_id}#{extension}"
    relative_path = Storage.generate_path(user_id, file_id, filename)

    case Storage.store(relative_path, binary_data, content_type: mime_type) do
      {:ok, _path} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:id, file_id)
        |> Ash.Changeset.force_change_attribute(:file_path, relative_path)
        |> Ash.Changeset.force_change_attribute(:file_size, byte_size(binary_data))
        |> Ash.Changeset.force_change_attribute(:storage_backend, Storage.backend_name())
        |> Ash.Changeset.force_change_attribute(:status, :ready)

      {:error, reason} ->
        Logger.error("StoreContent: Failed to store file: #{inspect(reason)}")

        Ash.Changeset.add_error(changeset,
          field: :content,
          message: "Storage failed: #{inspect(reason)}"
        )
    end
  end

  # Images
  defp mime_type_to_extension("image/png"), do: ".png"
  defp mime_type_to_extension("image/jpeg"), do: ".jpg"
  defp mime_type_to_extension("image/jpg"), do: ".jpg"
  defp mime_type_to_extension("image/gif"), do: ".gif"
  defp mime_type_to_extension("image/webp"), do: ".webp"

  # Video
  defp mime_type_to_extension("video/mp4"), do: ".mp4"
  defp mime_type_to_extension("video/webm"), do: ".webm"
  defp mime_type_to_extension("video/quicktime"), do: ".mov"

  # Documents - PDF
  defp mime_type_to_extension("application/pdf"), do: ".pdf"

  # Documents - Microsoft Office
  defp mime_type_to_extension("application/msword"), do: ".doc"

  defp mime_type_to_extension(
         "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
       ),
       do: ".docx"

  defp mime_type_to_extension("application/vnd.ms-excel"), do: ".xls"

  defp mime_type_to_extension(
         "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
       ),
       do: ".xlsx"

  defp mime_type_to_extension("application/vnd.ms-powerpoint"), do: ".ppt"

  defp mime_type_to_extension(
         "application/vnd.openxmlformats-officedocument.presentationml.presentation"
       ),
       do: ".pptx"

  # Documents - OpenDocument
  defp mime_type_to_extension("application/vnd.oasis.opendocument.text"), do: ".odt"
  defp mime_type_to_extension("application/vnd.oasis.opendocument.spreadsheet"), do: ".ods"
  defp mime_type_to_extension("application/vnd.oasis.opendocument.presentation"), do: ".odp"

  # Documents - E-books
  defp mime_type_to_extension("application/epub+zip"), do: ".epub"

  # Email
  defp mime_type_to_extension("message/rfc822"), do: ".eml"
  defp mime_type_to_extension("application/vnd.ms-outlook"), do: ".msg"

  # Text formats
  defp mime_type_to_extension("text/plain"), do: ".txt"
  defp mime_type_to_extension("text/markdown"), do: ".md"
  defp mime_type_to_extension("text/csv"), do: ".csv"
  defp mime_type_to_extension("text/html"), do: ".html"
  defp mime_type_to_extension("text/xml"), do: ".xml"
  defp mime_type_to_extension("application/xml"), do: ".xml"
  defp mime_type_to_extension("application/json"), do: ".json"

  # Fallback
  defp mime_type_to_extension(_), do: ".bin"
end
