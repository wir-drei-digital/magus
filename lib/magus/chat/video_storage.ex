defmodule Magus.Chat.VideoStorage do
  @moduledoc """
  Handles storage of generated videos from AI responses.

  Video generation APIs return URLs to generated videos. This module
  downloads and stores them using the same storage backend as user
  uploads (local filesystem or S3).
  """

  require Logger

  alias Magus.Files.Storage

  @doc """
  Download and store a video from a URL.

  ## Parameters
    - user_id: The user ID for path generation
    - video_url: URL of the video to download
    - opts: Options including:
      - :filename - Custom filename (default: generated UUID)
      - :timeout - Download timeout in ms (default: 300_000 = 5 min)

  ## Returns
    - {:ok, url} on success with local storage URL
    - {:error, reason} on failure
  """
  @spec store_video_from_url(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def store_video_from_url(user_id, video_url, opts \\ []) do
    filename = Keyword.get(opts, :filename, "#{Ash.UUIDv7.generate()}.mp4")
    timeout = Keyword.get(opts, :timeout, 300_000)

    Logger.info("VideoStorage: Downloading video",
      user_id: user_id,
      url: video_url
    )

    case download_video(video_url, timeout) do
      {:ok, binary_data, content_type} ->
        # Generate storage path
        resource_id = Ash.UUIDv7.generate()
        extension = content_type_to_extension(content_type)
        final_filename = ensure_extension(filename, extension)
        relative_path = Storage.generate_path(user_id, resource_id, final_filename)

        store_binary_video(relative_path, binary_data, content_type)

      {:error, reason} ->
        Logger.error("VideoStorage: Failed to download video", reason: inspect(reason))
        {:error, reason}
    end
  end

  @doc """
  Process a list of video attachments, downloading and storing each.

  Converts attachments with external URLs to local storage URLs.

  ## Parameters
    - user_id: The user ID for path generation
    - videos: List of video maps with url field

  ## Returns
    List of processed attachments with local url field
  """
  @spec process_video_attachments(String.t(), [map()]) :: [map()]
  def process_video_attachments(user_id, videos) do
    Logger.debug("VideoStorage: Processing #{length(videos)} videos")

    processed =
      videos
      |> Enum.map(fn video -> process_single_video(user_id, video) end)
      |> Enum.reject(&is_nil/1)

    Logger.debug("VideoStorage: Processed #{length(processed)} videos successfully")
    processed
  end

  # Process a single video attachment
  defp process_single_video(user_id, %{"type" => "video", "url" => url} = video)
       when is_binary(url) do
    # Check if URL is already local (starts with /)
    if String.starts_with?(url, "/") do
      video
    else
      case store_video_from_url(user_id, url) do
        {:ok, local_url} ->
          video
          |> Map.put("url", local_url)
          |> Map.put("original_url", url)

        {:error, reason} ->
          Logger.warning("VideoStorage: Failed to store video: #{inspect(reason)}")
          # Keep the original URL as fallback
          video
      end
    end
  end

  defp process_single_video(_user_id, video), do: video

  # Download video from URL
  defp download_video(url, timeout) do
    Logger.debug("VideoStorage: Starting download from #{url}")

    case Req.get(url, receive_timeout: timeout, max_retries: 2) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        Logger.debug("VideoStorage: Download successful, body size: #{byte_size(body)}")
        content_type = get_content_type(headers)
        {:ok, body, content_type}

      {:ok, %{status: status, body: body}} ->
        Logger.error("VideoStorage: HTTP error #{status}", body: inspect(body, limit: 200))
        {:error, {:http_error, status}}

      {:error, error} ->
        Logger.error("VideoStorage: Request error", error: inspect(error))
        {:error, error}
    end
  rescue
    e ->
      Logger.error("VideoStorage: Exception during download", error: inspect(e))
      {:error, {:exception, e}}
  end

  defp get_content_type(headers) do
    # Req returns headers as a map %{String.t() => [String.t()]}
    content_type =
      cond do
        # Map format (Req >= 0.4)
        is_map(headers) ->
          headers["content-type"] || Map.get(headers, "Content-Type")

        # List of tuples format (legacy)
        is_list(headers) ->
          Enum.find_value(headers, fn
            {"content-type", value} ->
              value

            {key, value} when is_binary(key) ->
              if String.downcase(key) == "content-type", do: value

            _ ->
              nil
          end)

        true ->
          nil
      end

    parse_content_type_value(content_type)
  end

  defp parse_content_type_value(nil), do: "video/mp4"

  defp parse_content_type_value([first | _]) when is_binary(first) do
    first
    |> String.split(";")
    |> List.first()
    |> String.trim()
  end

  defp parse_content_type_value(value) when is_binary(value) do
    value
    |> String.split(";")
    |> List.first()
    |> String.trim()
  end

  defp parse_content_type_value(_), do: "video/mp4"

  # Store binary video data
  defp store_binary_video(relative_path, binary_data, content_type) do
    Logger.debug("VideoStorage: Storing video",
      path: relative_path,
      size: byte_size(binary_data),
      content_type: content_type
    )

    case Storage.store(relative_path, binary_data, content_type: content_type) do
      {:ok, _path} ->
        case Storage.get_url(relative_path) do
          {:ok, url} ->
            Logger.info("VideoStorage: Video stored successfully",
              path: relative_path,
              size_mb: Float.round(byte_size(binary_data) / 1_000_000, 2)
            )

            {:ok, url}

          {:error, reason} ->
            Logger.error("VideoStorage: Failed to get URL", reason: inspect(reason))
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("VideoStorage: Failed to store video", reason: inspect(reason))
        {:error, reason}
    end
  end

  # Convert content type to file extension
  defp content_type_to_extension("video/mp4"), do: ".mp4"
  defp content_type_to_extension("video/webm"), do: ".webm"
  defp content_type_to_extension("video/quicktime"), do: ".mov"
  defp content_type_to_extension("video/x-msvideo"), do: ".avi"
  defp content_type_to_extension(_), do: ".mp4"

  # Ensure filename has the correct extension
  defp ensure_extension(filename, extension) do
    if String.ends_with?(filename, extension) do
      filename
    else
      Path.rootname(filename) <> extension
    end
  end
end
