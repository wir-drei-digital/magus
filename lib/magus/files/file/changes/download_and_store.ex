defmodule Magus.Files.File.Changes.DownloadAndStore do
  @moduledoc """
  Downloads content from a URL and stores it as a file.

  Used by the create_video_from_url action to fetch video content
  before storing it.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    # Skip download if content is already provided (useful for testing)
    existing_content = Ash.Changeset.get_argument(changeset, :content)

    if existing_content do
      # Content already provided, just set mime_type if not set
      if Ash.Changeset.get_attribute(changeset, :mime_type) do
        changeset
      else
        Ash.Changeset.change_attribute(changeset, :mime_type, "video/mp4")
      end
    else
      url = Ash.Changeset.get_argument(changeset, :url)
      timeout = Ash.Changeset.get_argument(changeset, :timeout) || 300_000

      case download_content(url, timeout) do
        {:ok, content, content_type} ->
          mime_type = normalize_video_mime_type(content_type)

          changeset
          |> Ash.Changeset.change_attribute(:mime_type, mime_type)
          |> Ash.Changeset.set_argument(:content, content)
          |> Ash.Changeset.set_argument(:content_encoding, :binary)

        {:error, reason} ->
          Ash.Changeset.add_error(changeset,
            field: :url,
            message: "Failed to download: #{inspect(reason)}"
          )
      end
    end
  end

  defp download_content(url, timeout) do
    case Req.get(url, receive_timeout: timeout, max_retries: 2) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        content_type = extract_content_type(headers) || "application/octet-stream"
        {:ok, body, content_type}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_content_type(headers) when is_map(headers) do
    case headers["content-type"] do
      [value | _] -> parse_content_type(value)
      value when is_binary(value) -> parse_content_type(value)
      _ -> nil
    end
  end

  defp extract_content_type(_), do: nil

  defp parse_content_type(value) when is_binary(value) do
    value |> String.split(";") |> List.first() |> String.trim()
  end

  defp normalize_video_mime_type("video/" <> _ = mime), do: mime
  defp normalize_video_mime_type(_), do: "video/mp4"
end
