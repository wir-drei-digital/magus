defmodule Magus.Files.Storage.S3 do
  @moduledoc """
  S3-compatible storage backend for production.

  Supports AWS S3, Tigris, MinIO, and other S3-compatible services.

  ## Configuration

  Configure in `config/runtime.exs`:

      config :magus, :s3,
        access_key_id: System.get_env("AWS_ACCESS_KEY_ID"),
        secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY"),
        region: System.get_env("AWS_REGION", "auto"),
        bucket: System.get_env("AWS_BUCKET"),
        host: System.get_env("AWS_S3_HOST"),
        scheme: "https://",
        prefix: "files"
  """

  @doc """
  Stores file content at the given relative path.
  Returns {:ok, relative_path} or {:error, reason}

  ## Options

    * `:content_type` - MIME type of the file (auto-detected if not provided)
  """
  def store(relative_path, content, opts \\ []) do
    bucket = bucket()
    key = build_key(relative_path)
    content_type = Keyword.get(opts, :content_type, determine_content_type(relative_path))
    config = build_config()

    case ExAws.S3.put_object(bucket, key, content, content_type: content_type)
         |> ExAws.request(config) do
      {:ok, _response} -> {:ok, relative_path}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Retrieves file content from the given relative path.
  Returns {:ok, content} or {:error, reason}
  """
  def get(relative_path) do
    bucket = bucket()
    key = build_key(relative_path)
    config = build_config()

    case ExAws.S3.get_object(bucket, key) |> ExAws.request(config) do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes file at the given relative path.
  Returns :ok or {:error, reason}
  """
  def delete(relative_path) do
    bucket = bucket()
    key = build_key(relative_path)
    config = build_config()

    case ExAws.S3.delete_object(bucket, key) |> ExAws.request(config) do
      {:ok, _response} -> :ok
      {:error, {:http_error, 404, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets a proxy URL for accessing the file through the authenticated controller.
  """
  def get_url(relative_path, _opts \\ []) do
    {:ok, "/uploads/files/#{relative_path}"}
  end

  @doc """
  Gets a presigned URL for uploading a file directly to S3.
  Useful for client-side uploads.

  ## Options

    * `:expires_in` - URL expiration time in seconds (default: 3600)
  """
  def get_upload_url(relative_path, opts \\ []) do
    bucket = bucket()
    key = build_key(relative_path)
    expires_in = Keyword.get(opts, :expires_in, 3600)
    config = build_config()

    ExAws.S3.presigned_url(config, :put, bucket, key, expires_in: expires_in)
  end

  # ============================================================================
  # Configuration
  # ============================================================================

  defp build_config do
    ExAws.Config.new(:s3)
  end

  defp bucket do
    Application.get_env(:magus, :s3_bucket) || System.get_env("AWS_BUCKET")
  end

  defp build_key(relative_path) do
    prefix = Application.get_env(:magus, :s3_prefix, "files")
    key = "#{prefix}/#{relative_path}"

    # Normalize and verify no path traversal escape
    normalized = key |> Path.expand("/") |> String.trim_leading("/")

    unless String.starts_with?(normalized, prefix <> "/") do
      raise ArgumentError, "Invalid path: path traversal attempt detected"
    end

    normalized
  end

  # ============================================================================
  # Content Type Detection
  # ============================================================================

  defp determine_content_type(filepath) do
    case Path.extname(filepath) |> String.downcase() do
      ext when ext in [".jpg", ".jpeg"] -> "image/jpeg"
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".svg" -> "image/svg+xml"
      ".pdf" -> "application/pdf"
      ".txt" -> "text/plain"
      ".md" -> "text/markdown"
      ".json" -> "application/json"
      ".csv" -> "text/csv"
      ".xml" -> "application/xml"
      ".html" -> "text/html"
      ".doc" -> "application/msword"
      ".docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      ".xls" -> "application/vnd.ms-excel"
      ".xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      ".ppt" -> "application/vnd.ms-powerpoint"
      ".pptx" -> "application/vnd.openxmlformats-officedocument.presentationml.presentation"
      ".zip" -> "application/zip"
      ".mp3" -> "audio/mpeg"
      ".mp4" -> "video/mp4"
      _ -> "application/octet-stream"
    end
  end
end
