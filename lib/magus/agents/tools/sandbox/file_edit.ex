defmodule Magus.Agents.Tools.Sandbox.FileEdit do
  @moduledoc """
  Jido tool for making targeted edits to files in the sandbox filesystem.

  Uses search-and-replace to modify specific parts of a file without rewriting
  the entire contents, saving tokens and reducing drift in unchanged code.
  """

  use Jido.Action,
    name: "sandbox_edit_file",
    description: """
    Make a targeted edit to a file in the sandbox using search-and-replace.

    Finds `old_string` in the file and replaces it with `new_string`.
    This is much more efficient than rewriting entire files.

    IMPORTANT RULES:
    - First use `sandbox_read_file` to see the current file contents.
    - `old_string` must match the actual file content EXACTLY, including whitespace and indentation.
    - Do NOT include line number prefixes (like "  1| " or " 10| ") in old_string or new_string.
      The line numbers shown by sandbox_read_file are display-only, not part of the file.
    - If the match is ambiguous (appears multiple times), provide more surrounding lines
      for context to make it unique, or set `replace_all` to true.
    - For creating new files or complete rewrites, use `sandbox_write_file` instead.

    ALTERNATIVE: Use `start_line` + `end_line` + `new_content` to replace a line range
    instead of string matching. This is easier when you know the exact line numbers.
    """,
    schema: [
      path: [
        type: :string,
        required: true,
        doc: "File path (absolute or relative to /workspace)"
      ],
      old_string: [
        type: {:or, [:string, nil]},
        required: false,
        default: nil,
        doc: "The exact text to find in the file (not needed when using start_line/end_line)"
      ],
      new_string: [
        type: {:or, [:string, nil]},
        required: false,
        default: nil,
        doc: "The replacement text (not needed when using start_line/end_line with new_content)"
      ],
      new_content: [
        type: {:or, [:string, nil]},
        required: false,
        default: nil,
        doc: "Replacement content for the line range (used with start_line/end_line)"
      ],
      start_line: [
        type: {:or, [:integer, nil]},
        required: false,
        default: nil,
        doc: "First line to replace (1-based, inclusive). Use with end_line + new_content."
      ],
      end_line: [
        type: {:or, [:integer, nil]},
        required: false,
        default: nil,
        doc: "Last line to replace (1-based, inclusive). Use with start_line + new_content."
      ],
      replace_all: [
        type: :boolean,
        required: false,
        default: false,
        doc: "Replace all occurrences (default: false, replaces only if unique)"
      ]
    ]

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2, maybe_unescape_content: 1]

  alias Magus.Agents.Signals
  alias Magus.Agents.Tools.Sandbox.SandboxHelpers
  alias Magus.Sandbox.Orchestrator

  def display_name, do: "Editing file..."

  def summarize_output(%{path: path, lines_replaced: range}),
    do: "Edited #{Path.basename(path)} (lines #{range})"

  def summarize_output(%{path: path, replacements: n}),
    do: "Edited #{Path.basename(path)} (#{n} replacement#{if n != 1, do: "s"})"

  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id, :user_id]) do
      {:ok, ctx} ->
        cond do
          params["start_line"] && params["end_line"] && params["new_content"] ->
            line_range_edit(ctx.conversation_id, ctx.user_id, params, context)

          params["old_string"] && params["new_string"] ->
            edit_file(ctx.conversation_id, ctx.user_id, params, context)

          true ->
            {:ok,
             %{
               error:
                 "Provide either old_string + new_string, or start_line + end_line + new_content."
             }}
        end

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp edit_file(conversation_id, user_id, params, context) do
    path = params["path"]
    old_string = params["old_string"] |> maybe_unescape_content()
    new_string = params["new_string"] |> maybe_unescape_content()
    replace_all = params["replace_all"] || false

    if old_string == new_string do
      {:ok, %{error: "old_string and new_string are identical. No edit needed."}}
    else
      do_edit(conversation_id, user_id, path, old_string, new_string, replace_all, context)
    end
  end

  defp do_edit(conversation_id, user_id, path, old_string, new_string, replace_all, context) do
    Signals.emit_tool_progress(context, :reading, %{
      message: "Reading #{Path.basename(path)}..."
    })

    case Orchestrator.read_file(conversation_id, path, user_id: user_id) do
      {:ok, result} ->
        apply_edit(conversation_id, user_id, result, old_string, new_string, replace_all, context)

      {:error, :not_found, message} ->
        {:ok, %{error: message, hint: "File not found. Check the path and try again."}}

      {:error, :not_configured, _} ->
        {:ok, %{error: "Sandbox not configured.", hint: "The sandbox service is not available."}}

      {:error, _type, details} ->
        {:ok, %{error: inspect(details)}}
    end
  end

  defp apply_edit(
         conversation_id,
         user_id,
         file_result,
         old_string,
         new_string,
         replace_all,
         context
       ) do
    content = file_result.content
    path = file_result.path

    case SandboxHelpers.apply_edit(content, old_string, new_string, replace_all) do
      {:ok, new_content, %{replacements: replacements}} ->
        Signals.emit_tool_progress(context, :writing, %{
          message: "Writing changes to #{Path.basename(path)}..."
        })

        case Orchestrator.write_file(conversation_id, path, new_content, user_id: user_id) do
          {:ok, write_result} ->
            diff = SandboxHelpers.build_unified_diff(content, new_content, Path.basename(path))

            {:ok,
             %{
               path: write_result.path,
               replacements: replacements,
               size_bytes: write_result.size_bytes,
               diff: diff
             }}

          {:error, :not_configured, _} ->
            {:ok,
             %{error: "Sandbox not configured.", hint: "The sandbox service is not available."}}

          {:error, _type, details} ->
            {:ok, %{error: inspect(details)}}
        end

      {:error, :not_found, _} ->
        # Try fuzzy matching for a helpful suggestion
        case SandboxHelpers.find_closest_match(content, old_string) do
          {:fuzzy, _match, candidate} ->
            {:ok,
             %{
               error:
                 "Exact match not found in #{Path.basename(path)}, but a similar match was found.",
               hint:
                 "Use this exact text as old_string instead:\n\n#{candidate}\n\n" <>
                   "Or use start_line/end_line/new_content for line-range replacement.",
               suggestion: candidate
             }}

          _ ->
            {:ok,
             %{
               error: "old_string not found in #{Path.basename(path)}.",
               hint:
                 "Use sandbox_read_file to check the current file contents. " <>
                   "The old_string must match exactly, including whitespace and indentation. " <>
                   "Do NOT include line number prefixes (e.g. '  1| '). " <>
                   "Alternatively, use start_line/end_line/new_content for line-range replacement."
             }}
        end

      {:error, :multiple_matches, occurrences} ->
        {:ok,
         %{
           error:
             "old_string appears #{occurrences} times in #{Path.basename(path)}. " <>
               "Provide more surrounding context to make the match unique, or set replace_all to true.",
           occurrences: occurrences
         }}
    end
  end

  defp line_range_edit(conversation_id, user_id, params, context) do
    path = params["path"]
    start_line = params["start_line"]
    end_line = params["end_line"]
    new_content = params["new_content"] |> maybe_unescape_content()

    if end_line < start_line do
      {:ok, %{error: "end_line (#{end_line}) must be >= start_line (#{start_line})."}}
    else
      Signals.emit_tool_progress(context, :reading, %{
        message: "Reading #{Path.basename(path)}..."
      })

      case Orchestrator.read_file(conversation_id, path, user_id: user_id) do
        {:ok, result} ->
          apply_line_range_edit(
            conversation_id,
            user_id,
            result,
            start_line,
            end_line,
            new_content,
            context
          )

        {:error, :not_found, message} ->
          {:ok, %{error: message, hint: "File not found. Check the path and try again."}}

        {:error, :not_configured, _} ->
          {:ok, %{error: "Sandbox not configured."}}

        {:error, _type, details} ->
          {:ok, %{error: inspect(details)}}
      end
    end
  end

  defp apply_line_range_edit(
         conversation_id,
         user_id,
         file_result,
         start_line,
         end_line,
         new_content,
         context
       ) do
    content = file_result.content
    path = file_result.path
    lines = String.split(content, "\n")
    total_lines = length(lines)

    cond do
      start_line < 1 ->
        {:ok, %{error: "start_line must be >= 1, got #{start_line}."}}

      start_line > total_lines ->
        {:ok, %{error: "start_line #{start_line} exceeds file length (#{total_lines} lines)."}}

      true ->
        clamped_end = min(end_line, total_lines)
        before = Enum.take(lines, start_line - 1)
        after_lines = Enum.drop(lines, clamped_end)

        new_lines = String.split(new_content, "\n")
        new_full = Enum.join(before ++ new_lines ++ after_lines, "\n")

        Signals.emit_tool_progress(context, :writing, %{
          message: "Replacing lines #{start_line}-#{clamped_end} in #{Path.basename(path)}..."
        })

        case Orchestrator.write_file(conversation_id, path, new_full, user_id: user_id) do
          {:ok, write_result} ->
            diff = SandboxHelpers.build_unified_diff(content, new_full, Path.basename(path))

            {:ok,
             %{
               path: write_result.path,
               lines_replaced: "#{start_line}-#{clamped_end}",
               size_bytes: write_result.size_bytes,
               diff: diff
             }}

          {:error, :not_configured, _} ->
            {:ok, %{error: "Sandbox not configured."}}

          {:error, _type, details} ->
            {:ok, %{error: inspect(details)}}
        end
    end
  end
end
