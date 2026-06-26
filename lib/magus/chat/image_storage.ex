defmodule Magus.Chat.ImageStorage do
  @moduledoc """
  Handles storage of generated images from AI responses.

  Uses the same storage backend (local/S3) as user-uploaded attachments.
  """

  require Logger

  alias Magus.Files.Storage

  @doc """
  Store a base64-encoded image and return its storage URL.

  ## Parameters
    - user_id: The user ID for path generation
    - base64_data: Raw base64 string (without data URL prefix)
    - opts: Options including:
      - :mime_type - MIME type (default: "image/png")
      - :filename - Custom filename (default: generated UUID)

  ## Returns
    - {:ok, url} on success
    - {:error, reason} on failure
  """
  @spec store_base64_image(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def store_base64_image(user_id, base64_data, opts \\ []) do
    mime_type = Keyword.get(opts, :mime_type, "image/png")
    extension = mime_type_to_extension(mime_type)
    filename = Keyword.get(opts, :filename, "#{Ash.UUIDv7.generate()}#{extension}")

    # Generate a unique resource ID for the file
    resource_id = Ash.UUIDv7.generate()
    relative_path = Storage.generate_path(user_id, resource_id, filename)

    # Decode the base64 data
    case Base.decode64(base64_data) do
      {:ok, binary_data} ->
        store_binary_image(relative_path, binary_data, mime_type)

      :error ->
        Logger.error("ImageStorage: Failed to decode base64 image data")
        {:error, :invalid_base64}
    end
  end

  @doc """
  Store a data URL image and return its storage URL.

  Handles the data:image/png;base64,... format.

  ## Parameters
    - user_id: The user ID for path generation
    - data_url: Full data URL string

  ## Returns
    - {:ok, url} on success
    - {:error, reason} on failure
  """
  @spec store_data_url_image(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def store_data_url_image(user_id, data_url) do
    case parse_data_url(data_url) do
      {:ok, mime_type, base64_data} ->
        store_base64_image(user_id, base64_data, mime_type: mime_type)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Process a list of image attachments, uploading each to storage.

  Converts attachments with data_url or base64 to stored URLs.

  ## Parameters
    - user_id: The user ID for path generation
    - attachments: List of attachment maps with data_url or base64 fields

  ## Returns
    List of processed attachments with url field instead of data_url
  """
  @spec process_image_attachments(String.t(), [map()]) :: [map()]
  def process_image_attachments(user_id, attachments) do
    Logger.debug("ImageStorage: Processing #{length(attachments)} attachments",
      attachments: inspect(attachments, limit: 500)
    )

    processed =
      attachments
      |> Enum.map(fn attachment -> process_single_attachment(user_id, attachment) end)
      |> deduplicate_by_url()

    Logger.debug("ImageStorage: Processed #{length(processed)} unique attachments")
    processed
  end

  # Deduplicate attachments by URL or data_url to prevent duplicates
  defp deduplicate_by_url(attachments) do
    attachments
    |> Enum.uniq_by(fn att ->
      Map.get(att, "url") || Map.get(att, "data_url") || :rand.uniform()
    end)
  end

  # Process a single attachment
  defp process_single_attachment(
         user_id,
         %{"type" => "image", "data_url" => data_url} = attachment
       )
       when is_binary(data_url) do
    case store_data_url_image(user_id, data_url) do
      {:ok, url} ->
        attachment
        |> Map.delete("data_url")
        |> Map.put("url", url)

      {:error, reason} ->
        Logger.warning("ImageStorage: Failed to store image: #{inspect(reason)}")
        # Keep the original data_url as fallback
        attachment
    end
  end

  defp process_single_attachment(user_id, %{"type" => "image", "base64" => base64} = attachment)
       when is_binary(base64) do
    mime_type = Map.get(attachment, "mime_type", "image/png")

    case store_base64_image(user_id, base64, mime_type: mime_type) do
      {:ok, url} ->
        attachment
        |> Map.delete("base64")
        |> Map.delete("mime_type")
        |> Map.put("url", url)

      {:error, reason} ->
        Logger.warning("ImageStorage: Failed to store image: #{inspect(reason)}")
        # Convert to data_url as fallback
        Map.put(attachment, "data_url", "data:#{mime_type};base64,#{base64}")
    end
  end

  defp process_single_attachment(_user_id, attachment), do: attachment

  # Store binary image data
  defp store_binary_image(relative_path, binary_data, mime_type) do
    Logger.debug("ImageStorage: Storing image",
      path: relative_path,
      size: byte_size(binary_data),
      mime_type: mime_type
    )

    case Storage.store(relative_path, binary_data, content_type: mime_type) do
      {:ok, _path} ->
        # Get the URL for the stored file
        case Storage.get_url(relative_path) do
          {:ok, url} ->
            Logger.info("ImageStorage: Image stored successfully", path: relative_path)
            {:ok, url}

          {:error, reason} ->
            Logger.error("ImageStorage: Failed to get URL", reason: inspect(reason))
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("ImageStorage: Failed to store image", reason: inspect(reason))
        {:error, reason}
    end
  end

  # Parse a data URL into mime type and base64 data
  defp parse_data_url(data_url) when is_binary(data_url) do
    case Regex.run(~r/^data:([^;]+);base64,(.+)$/s, data_url) do
      [_, mime_type, base64_data] ->
        {:ok, mime_type, base64_data}

      nil ->
        {:error, :invalid_data_url}
    end
  end

  defp parse_data_url(_), do: {:error, :invalid_data_url}

  # Convert MIME type to file extension
  defp mime_type_to_extension("image/png"), do: ".png"
  defp mime_type_to_extension("image/jpeg"), do: ".jpg"
  defp mime_type_to_extension("image/jpg"), do: ".jpg"
  defp mime_type_to_extension("image/gif"), do: ".gif"
  defp mime_type_to_extension("image/webp"), do: ".webp"
  defp mime_type_to_extension("image/svg+xml"), do: ".svg"
  defp mime_type_to_extension(_), do: ".png"
end
