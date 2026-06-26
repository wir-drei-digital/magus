defmodule Magus.Files.Storage.Local do
  @moduledoc """
  Local filesystem storage backend for development and testing.

  Stores files in `priv/static/uploads/files` directory.
  """

  @base_path "priv/static/uploads/files"

  @doc """
  Returns the base path for local storage.
  """
  def base_path, do: @base_path

  @doc """
  Returns the full local filesystem path for a relative storage path.

  Includes path traversal protection to prevent accessing files outside
  the storage directory.
  """
  def full_path(relative_path) do
    base = Path.join([File.cwd!(), @base_path]) |> Path.expand()
    # Expand the path to resolve any ".." or "." components
    full = Path.join([base, relative_path]) |> Path.expand()

    # Ensure the resolved path is within the base directory. A bare prefix check
    # would also accept a sibling dir that shares the prefix (e.g. "<base>_evil"),
    # so require an exact match or a path strictly under "<base>/".
    unless full == base or String.starts_with?(full, base <> "/") do
      raise ArgumentError, "Invalid path: path traversal attempt detected"
    end

    full
  end

  @doc """
  Stores file content at the given relative path.
  Returns {:ok, relative_path} or {:error, reason}
  """
  def store(relative_path, content, _opts \\ []) do
    path = full_path(relative_path)
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, content) do
      {:ok, relative_path}
    end
  end

  @doc """
  Retrieves file content from the given relative path.
  Returns {:ok, content} or {:error, reason}
  """
  def get(relative_path) do
    path = full_path(relative_path)
    File.read(path)
  end

  @doc """
  Deletes file at the given relative path.
  Returns :ok or {:error, reason}
  """
  def delete(relative_path) do
    path = full_path(relative_path)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  @doc """
  Gets a URL for accessing the file.
  Returns a static path for serving via Phoenix.
  """
  def get_url(relative_path, _opts \\ []) do
    {:ok, "/uploads/files/#{relative_path}"}
  end
end
