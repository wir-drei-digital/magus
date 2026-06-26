defmodule Magus.Sandbox.WorkspaceManager do
  @moduledoc """
  Manages the /workspace directory in sandboxes.

  Provides a structured workspace where all user code and generated files live.
  Files in /workspace are listed after execution and shown in the UI with download buttons.
  """

  alias Magus.Sandbox.Provider

  @workspace_dir "/workspace"

  # Skip dot-prefixed directories (caches, config dirs, etc.)
  @skip_prefixes [".", "__pycache__"]

  # Limits for workspace listing
  @max_depth 3
  @max_entries 200

  @doc """
  Returns the workspace root directory path.
  """
  def workspace_dir, do: @workspace_dir

  @doc """
  Setup the workspace directory in a sandbox.

  Creates `/workspace` if it doesn't exist.
  """
  @spec setup(map()) :: :ok | {:error, term()}
  def setup(sandbox) do
    client = Provider.client_for(sandbox)
    client.ensure_directory(sandbox.sprite_id, @workspace_dir)
  end

  @doc """
  Copy files to the workspace directory.

  ## Parameters

    * `sandbox` - The sandbox struct
    * `files` - List of files with `:name` and `:content` keys

  ## Returns

    * `{:ok, [filename]}` - List of successfully copied filenames
    * `{:error, reason}` - If any file copy fails
  """
  @spec copy_files(map(), list(map())) :: {:ok, list(String.t())} | {:error, term()}
  def copy_files(sandbox, files) when is_list(files) do
    client = Provider.client_for(sandbox)

    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, copied} ->
      target_path = Path.join(@workspace_dir, file.name)

      case client.write_file(sandbox.sprite_id, target_path, file.content) do
        :ok -> {:cont, {:ok, [file.name | copied]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Copy a single file to the workspace directory.

  ## Parameters

    * `sandbox` - The sandbox struct
    * `filename` - Target filename (will be placed in /workspace)
    * `content` - File content as binary

  ## Returns

    * `:ok` - File copied successfully
    * `{:error, reason}` - If copy fails
  """
  @spec copy_file(map(), String.t(), binary()) :: :ok | {:error, term()}
  def copy_file(sandbox, filename, content) do
    client = Provider.client_for(sandbox)
    target_path = Path.join(@workspace_dir, filename)
    client.write_file(sandbox.sprite_id, target_path, content)
  end

  @doc """
  Clean up the workspace by removing all contents.
  """
  @spec cleanup(map()) :: :ok | {:error, term()}
  def cleanup(sandbox) do
    client = Provider.client_for(sandbox)

    with :ok <- client.reset(sandbox.sprite_id, @workspace_dir),
         :ok <- client.ensure_directory(sandbox.sprite_id, @workspace_dir) do
      :ok
    end
  end

  @doc """
  Recursively list all files in /workspace, skipping dot-prefixed directories.

  Returns a flat list of file entries with name, path, size, and is_dir flag.
  Max depth #{@max_depth}, max #{@max_entries} entries.

  ## Returns

    * `{:ok, [%{name, path, size, is_dir}]}` - List of workspace files
    * `{:error, reason}` - If listing fails
  """
  @spec list_workspace_files(map()) :: {:ok, list(map())} | {:error, term()}
  def list_workspace_files(sandbox) do
    client = Provider.client_for(sandbox)

    case do_list(client, sandbox.sprite_id, @workspace_dir, 0, []) do
      {:ok, entries} ->
        {:ok, entries |> Enum.reverse() |> Enum.take(@max_entries)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_list(client, sprite_id, dir, depth, acc) when depth < @max_depth do
    case client.list_files(sprite_id, dir) do
      {:ok, entries} when is_list(entries) ->
        Enum.reduce_while(entries, {:ok, acc}, fn entry, {:ok, current_acc} ->
          name = entry["name"] || ""
          is_dir = entry["isDir"] == true
          size = entry["size"] || 0
          path = Path.join(dir, name)

          if skip_entry?(name) do
            {:cont, {:ok, current_acc}}
          else
            entry_map = %{name: name, path: path, size: size, is_dir: is_dir}
            new_acc = [entry_map | current_acc]

            if is_dir and length(new_acc) < @max_entries do
              case do_list(client, sprite_id, path, depth + 1, new_acc) do
                {:ok, deeper_acc} -> {:cont, {:ok, deeper_acc}}
                {:error, _} -> {:cont, {:ok, new_acc}}
              end
            else
              {:cont, {:ok, new_acc}}
            end
          end
        end)

      {:ok, _} ->
        {:ok, acc}

      {:error, :enoent} ->
        {:ok, acc}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_list(_client, _sprite_id, _dir, _depth, acc), do: {:ok, acc}

  defp skip_entry?(name) do
    Enum.any?(@skip_prefixes, &String.starts_with?(name, &1))
  end
end
