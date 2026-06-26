defmodule Magus.Agents.Tools.Sandbox.FileList do
  @moduledoc """
  Jido tool for listing files and directories in the sandbox.
  """

  use Jido.Action,
    name: "sandbox_list_files",
    description: """
    List files and directories in the sandbox filesystem.

    Paths can be absolute or relative to /workspace.
    Use recursive mode to see the full directory tree (limited to depth 3).
    Use the pattern parameter to filter by filename glob (e.g. "*.py", "*.test.*").

    Use this to explore the workspace, find files by name, check what files exist,
    or verify build output.
    """,
    schema: [
      path: [
        type: :string,
        required: false,
        default: "/workspace",
        doc: "Directory path (default: /workspace)"
      ],
      pattern: [
        type: {:or, [:string, nil]},
        required: false,
        default: nil,
        doc: "Glob pattern to filter filenames (e.g. \"*.py\", \"*.test.*\", \"Makefile\")"
      ],
      recursive: [
        type: :boolean,
        required: false,
        default: false,
        doc: "List files recursively (default: false, max depth: 3)"
      ]
    ]

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2]

  alias Magus.Agents.Signals
  alias Magus.Sandbox.Orchestrator

  @max_depth 3
  @max_entries 500

  def display_name, do: "Listing files..."

  def summarize_output(%{entries: entries}) when is_list(entries),
    do: "#{length(entries)} entries"

  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id, :user_id]) do
      {:ok, ctx} ->
        list_files(ctx.conversation_id, ctx.user_id, params, context)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp list_files(conversation_id, user_id, params, context) do
    path = params["path"] || "/workspace"
    recursive = params["recursive"] || false
    pattern = params["pattern"]

    Signals.emit_tool_progress(context, :listing, %{message: "Listing #{path}..."})

    if pattern do
      list_with_pattern(conversation_id, user_id, path, pattern, recursive)
    else
      list_without_pattern(conversation_id, user_id, path, recursive)
    end
  end

  defp list_with_pattern(conversation_id, user_id, path, pattern, recursive) do
    max_depth = if recursive, do: "-maxdepth #{@max_depth}", else: "-maxdepth 1"
    escaped_pattern = String.replace(pattern, "'", "'\\''")
    escaped_path = String.replace(path, "'", "'\\''")

    command =
      "find '#{escaped_path}' #{max_depth} -name '#{escaped_pattern}' -type f | sort | head -n #{@max_entries}"

    opts = [
      timeout_ms: 10_000,
      working_dir: "/workspace",
      description: "find files by pattern",
      user_id: user_id
    ]

    case Orchestrator.exec_command(conversation_id, command, opts) do
      {:ok, %{stdout: stdout}} ->
        entries =
          (stdout || "")
          |> String.split("\n", trim: true)
          |> Enum.map(fn file_path ->
            %{
              name: Path.basename(file_path),
              path: file_path,
              size: nil,
              is_dir: false
            }
          end)

        {:ok, %{entries: entries, path: path, pattern: pattern, recursive: recursive}}

      {:error, :not_configured, _} ->
        {:ok, %{error: "Sandbox not configured."}}

      {:error, _type, details} ->
        {:ok, %{error: inspect(details)}}
    end
  end

  defp list_without_pattern(conversation_id, user_id, path, recursive) do
    case Orchestrator.list_files(conversation_id, path, user_id: user_id) do
      {:ok, entries} ->
        formatted = format_entries(entries, path)

        if recursive do
          remaining = @max_entries - length(formatted)
          sub_entries = list_recursive(conversation_id, user_id, entries, path, 1, remaining)
          {:ok, %{entries: formatted ++ sub_entries, path: path, recursive: true}}
        else
          {:ok, %{entries: formatted, path: path, recursive: false}}
        end

      {:error, :not_found, message} ->
        {:ok, %{error: message, hint: "Directory not found. Check the path."}}

      {:error, :not_configured, _} ->
        {:ok, %{error: "Sandbox not configured.", hint: "The sandbox service is not available."}}

      {:error, _type, details} ->
        {:ok, %{error: inspect(details)}}
    end
  end

  defp list_recursive(_conversation_id, _user_id, _entries, _parent, depth, _remaining)
       when depth >= @max_depth,
       do: []

  defp list_recursive(_conversation_id, _user_id, _entries, _parent, _depth, remaining)
       when remaining <= 0,
       do: []

  defp list_recursive(conversation_id, user_id, entries, parent_path, depth, remaining) do
    entries
    |> Enum.filter(fn entry -> entry["isDir"] == true end)
    |> Enum.reduce_while({[], remaining}, fn dir_entry, {acc, rem} ->
      sub_path = Path.join(parent_path, dir_entry["name"])

      case Orchestrator.list_files(conversation_id, sub_path, user_id: user_id) do
        {:ok, sub_entries} ->
          formatted = format_entries(sub_entries, sub_path) |> Enum.take(rem)
          new_rem = rem - length(formatted)

          deeper =
            list_recursive(conversation_id, user_id, sub_entries, sub_path, depth + 1, new_rem)

          new_rem = new_rem - length(deeper)

          if new_rem <= 0 do
            {:halt, {acc ++ formatted ++ deeper, 0}}
          else
            {:cont, {acc ++ formatted ++ deeper, new_rem}}
          end

        {:error, _, _} ->
          {:cont, {acc, rem}}
      end
    end)
    |> elem(0)
  end

  defp format_entries(entries, parent_path) do
    Enum.map(entries, fn entry ->
      %{
        name: entry["name"],
        path: Path.join(parent_path, entry["name"]),
        size: entry["size"],
        is_dir: entry["isDir"] == true
      }
    end)
  end
end
