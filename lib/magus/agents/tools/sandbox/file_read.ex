defmodule Magus.Agents.Tools.Sandbox.FileRead do
  @moduledoc """
  Jido tool for reading files from the sandbox filesystem.
  """

  use Jido.Action,
    name: "sandbox_read_file",
    description: """
    Read file contents from the sandbox filesystem with line numbers.

    Paths can be absolute or relative to /workspace.
    For binary files (images, PDFs, etc.), returns metadata only.

    Output includes line numbers (e.g. "  1| code here") for reference.
    These prefixes are display-only -- do NOT include them when using sandbox_edit_file.

    Use `start_line` and `end_line` to read specific sections.
    For large files, read the whole file first to orient, then read specific sections.
    """,
    schema: [
      path: [
        type: :string,
        required: true,
        doc: "File path (absolute or relative to /workspace)"
      ],
      max_lines: [
        type: :integer,
        required: false,
        default: 500,
        doc: "Maximum number of lines to return (default: 500)"
      ],
      start_line: [
        type: :integer,
        required: false,
        doc: "First line to return (1-based, inclusive). Omit to start from the beginning."
      ],
      end_line: [
        type: :integer,
        required: false,
        doc: "Last line to return (1-based, inclusive). Omit to read to the end."
      ]
    ]

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2]

  alias Magus.Agents.Signals
  alias Magus.Sandbox.Orchestrator

  @binary_extensions ~w(.png .jpg .jpeg .gif .bmp .ico .svg .webp .pdf .zip .tar .gz .bz2
    .7z .rar .exe .bin .so .dylib .woff .woff2 .ttf .otf .eot .mp3 .mp4 .wav
    .avi .mov .webm .ogg .xlsx .xls .docx .pptx)

  def display_name, do: "Reading file..."

  def summarize_output(%{content: content}) when is_binary(content) do
    lines = content |> String.split("\n") |> length()
    "#{lines} lines"
  end

  def summarize_output(%{binary: true, size_bytes: size}),
    do: "Binary file (#{format_size(size)})"

  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id, :user_id]) do
      {:ok, ctx} ->
        read_file(ctx.conversation_id, ctx.user_id, params, context)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp read_file(conversation_id, user_id, params, context) do
    path = params["path"]
    max_lines = params["max_lines"] || 500
    start_line = params["start_line"]
    end_line = params["end_line"]

    Signals.emit_tool_progress(context, :reading, %{message: "Reading #{Path.basename(path)}..."})

    if binary_extension?(path) do
      {:ok,
       %{
         binary: true,
         path: path,
         size_bytes: nil,
         hint: "This is a binary file. Use exec_command to inspect it (e.g., file, xxd, etc.)."
       }}
    else
      case Orchestrator.read_file(conversation_id, path, user_id: user_id) do
        {:ok, result} ->
          content =
            result.content
            |> apply_line_range(start_line, end_line)
            |> add_line_numbers(start_line || 1)
            |> truncate_lines(max_lines)

          total_lines = result.content |> String.split("\n") |> length()

          response = %{
            content: content,
            path: result.path,
            size_bytes: result.size_bytes,
            total_lines: total_lines
          }

          response =
            if start_line || end_line do
              Map.put(response, :range, %{
                start_line: start_line || 1,
                end_line: min(end_line || total_lines, total_lines)
              })
            else
              response
            end

          response =
            if total_lines > 500 and is_nil(start_line) and is_nil(end_line) do
              Map.put(
                response,
                :hint,
                "Large file (#{total_lines} lines). Use start_line/end_line to read specific sections."
              )
            else
              response
            end

          {:ok, response}

        {:error, :not_found, message} ->
          {:ok, %{error: message, hint: "File not found. Check the path and try again."}}

        {:error, :not_configured, _} ->
          {:ok,
           %{error: "Sandbox not configured.", hint: "The sandbox service is not available."}}

        {:error, _type, details} ->
          {:ok, %{error: inspect(details)}}
      end
    end
  end

  defp binary_extension?(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in @binary_extensions
  end

  defp apply_line_range(content, nil, nil), do: content

  defp apply_line_range(content, start_line, end_line) when is_binary(content) do
    lines = String.split(content, "\n")
    start_idx = max((start_line || 1) - 1, 0)
    end_idx = (end_line || length(lines)) - 1

    lines
    |> Enum.slice(start_idx..end_idx//1)
    |> Enum.join("\n")
  end

  defp add_line_numbers(content, first_line_num) when is_binary(content) do
    lines = String.split(content, "\n")
    last_num = first_line_num + length(lines) - 1
    width = last_num |> Integer.to_string() |> String.length()

    lines
    |> Enum.with_index(first_line_num)
    |> Enum.map(fn {line, num} ->
      num_str = num |> Integer.to_string() |> String.pad_leading(width)
      "#{num_str}| #{line}"
    end)
    |> Enum.join("\n")
  end

  defp truncate_lines(content, max_lines) when is_binary(content) do
    lines = String.split(content, "\n")
    total = length(lines)

    if total > max_lines do
      lines
      |> Enum.take(max_lines)
      |> Enum.join("\n")
      |> Kernel.<>("\n... (truncated at #{max_lines} lines, #{total} total)")
    else
      content
    end
  end

  defp truncate_lines(content, _), do: content

  defp format_size(nil), do: "unknown"
  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
