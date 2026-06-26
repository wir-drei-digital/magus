defmodule Magus.Files.Storage do
  @moduledoc """
  Abstraction layer for file storage.

  Delegates to the configured backend:
  - `Magus.Files.Storage.Local` - Local filesystem (development/test)
  - `Magus.Files.Storage.S3` - S3-compatible storage (production)

  The backend is determined by the `:storage_backend` application config.
  """

  alias Magus.Files.Storage.{Local, S3}

  @doc """
  Returns the configured storage backend.
  """
  def backend do
    Application.get_env(:magus, :storage_backend, :local)
  end

  @doc """
  Stores file content at the given relative path.
  Returns {:ok, relative_path} or {:error, reason}

  ## Options

    * `:backend` - Override the configured backend
    * `:content_type` - MIME type (S3 only, auto-detected if not provided)
  """
  def store(relative_path, content, opts \\ []) do
    case get_backend(opts) do
      :local -> Local.store(relative_path, content, opts)
      :s3 -> S3.store(relative_path, content, opts)
    end
  end

  @doc """
  Retrieves file content from the given relative path.
  Returns {:ok, content} or {:error, reason}
  """
  def get(relative_path, opts \\ []) do
    case get_backend(opts) do
      :local -> Local.get(relative_path)
      :s3 -> S3.get(relative_path)
    end
  end

  @doc """
  Deletes file at the given relative path.
  Returns :ok or {:error, reason}
  """
  def delete(relative_path, opts \\ []) do
    case get_backend(opts) do
      :local -> Local.delete(relative_path)
      :s3 -> S3.delete(relative_path)
    end
  end

  @doc """
  Gets a URL for accessing the file.
  Returns a proxy path (`/uploads/files/{path}`) that routes through the
  authenticated `FileController` regardless of the storage backend.

  ## Options

    * `:backend` - Override the configured backend
  """
  def get_url(relative_path, opts \\ []) do
    case get_backend(opts) do
      :local -> Local.get_url(relative_path, opts)
      :s3 -> S3.get_url(relative_path, opts)
    end
  end

  @doc """
  Generates a storage path for a file.
  """
  def generate_path(user_id, file_id, filename) do
    ext = Path.extname(filename)
    "#{user_id}/#{file_id}#{ext}"
  end

  @doc """
  Fetches file content from a URL.

  Handles both local storage URLs (e.g., `/uploads/files/...`) and
  external URLs (e.g., `https://s3.example.com/...`).

  Returns `{:ok, binary, content_type}` or `{:error, reason}`.
  """
  def get_from_url(url, opts \\ [])

  def get_from_url(url, opts) when is_binary(url) do
    cond do
      # External URL - fetch via HTTP
      String.starts_with?(url, "http://") or String.starts_with?(url, "https://") ->
        fetch_external_url(url, opts)

      # Local storage URL (e.g., /uploads/files/...)
      String.starts_with?(url, "/uploads/files/") ->
        # Extract relative path from URL
        relative_path = String.replace_prefix(url, "/uploads/files/", "")
        # Remove any query params
        relative_path = relative_path |> String.split("?") |> List.first()

        case get(relative_path) do
          {:ok, content} ->
            content_type = mime_type_from_path(url)
            {:ok, content, content_type}

          {:error, reason} ->
            {:error, reason}
        end

      # Legacy URL format (e.g., /uploads/memory/...)
      String.starts_with?(url, "/uploads/memory/") ->
        relative_path = String.replace_prefix(url, "/uploads/memory/", "")
        relative_path = relative_path |> String.split("?") |> List.first()

        case Local.get(relative_path) do
          {:ok, content} ->
            content_type = mime_type_from_path(url)
            {:ok, content, content_type}

          {:error, reason} ->
            {:error, reason}
        end

      true ->
        {:error, :invalid_url}
    end
  end

  def get_from_url(_, _opts), do: {:error, :invalid_url}

  @doc """
  Fetches file content from a URL and returns it as a base64-encoded data URI.

  Returns `{:ok, data_uri}` or `{:error, reason}`.
  """
  def get_as_data_uri(url, opts \\ []) do
    case get_from_url(url, opts) do
      {:ok, content, content_type} ->
        base64 = Base.encode64(content)
        {:ok, "data:#{content_type};base64,#{base64}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches file content from a URL and returns it as a base64-encoded map.

  Returns `{:ok, %{data: base64, media_type: content_type}}` or `{:error, reason}`.
  """
  def get_as_base64(url, opts \\ []) do
    case get_from_url(url, opts) do
      {:ok, content, content_type} ->
        {:ok, %{data: Base.encode64(content), media_type: content_type}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private

  defp get_backend(opts) do
    Keyword.get(opts, :backend, backend())
  end

  defp fetch_external_url(url, _opts) do
    case Req.get(url, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body, headers: headers}} when is_binary(body) ->
        content_type = extract_content_type(headers) || mime_type_from_path(url)
        {:ok, body, content_type}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_content_type(headers) do
    headers
    |> Enum.find(fn {key, _} -> String.downcase(key) == "content-type" end)
    |> case do
      {_, [value | _]} when is_binary(value) ->
        value |> String.split(";") |> List.first() |> String.trim()

      {_, value} when is_binary(value) ->
        value |> String.split(";") |> List.first() |> String.trim()

      _ ->
        nil
    end
  end

  defp mime_type_from_path(path) do
    # Remove query params for extension detection
    clean_path = path |> String.split("?") |> List.first()

    case Path.extname(clean_path) |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".mp4" -> "video/mp4"
      ".webm" -> "video/webm"
      _ -> "application/octet-stream"
    end
  end
end
