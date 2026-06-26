defmodule Magus.Agents.Tools.Sandbox.FileSearch do
  @moduledoc """
  Jido tool for searching file contents across the sandbox workspace using ripgrep (with grep fallback).
  """

  use Jido.Action,
    name: "sandbox_search",
    description: """
    Search file contents across the sandbox workspace.

    Uses ripgrep (rg) with a grep fallback to find lines matching a pattern in files under a given path.
    Supports multiple output modes, context lines, case-insensitive search, multiline patterns, and type filters.

    Use this to:
    - Find where a function, variable, or class is defined or used
    - Locate configuration values or error messages
    - Discover which files contain a specific import or pattern
    - Count occurrences per file with "count" mode
    - List only matching file paths with "files_with_matches" mode

    Combine with `sandbox_read_file` (with start_line/end_line) to read
    the surrounding context of a match.
    """,
    schema: [
      pattern: [
        type: :string,
        required: true,
        doc: "Search pattern (ripgrep regex)"
      ],
      path: [
        type: :string,
        required: false,
        default: "/workspace",
        doc: "Directory or file to search in (default: /workspace)"
      ],
      include: [
        type: {:or, [:string, nil]},
        required: false,
        default: nil,
        doc: "Glob pattern to filter files (e.g. \"*.py\", \"*.{js,ts}\")"
      ],
      max_results: [
        type: :integer,
        required: false,
        default: 250,
        doc: "Maximum number of matches to return (default: 250)"
      ],
      output_mode: [
        type: :string,
        required: false,
        default: "content",
        doc:
          "Output mode: \"content\" (file:line:text), \"files_with_matches\" (paths only), \"count\" (file:count)"
      ],
      case_insensitive: [
        type: :boolean,
        required: false,
        default: false,
        doc: "Case-insensitive search (default: false)"
      ],
      context_before: [
        type: {:or, [:integer, nil]},
        required: false,
        default: nil,
        doc: "Lines of context to show before each match (content mode only)"
      ],
      context_after: [
        type: {:or, [:integer, nil]},
        required: false,
        default: nil,
        doc: "Lines of context to show after each match (content mode only)"
      ],
      context: [
        type: {:or, [:integer, nil]},
        required: false,
        default: nil,
        doc:
          "Lines of context before AND after each match, shorthand for context_before + context_after (content mode only)"
      ],
      multiline: [
        type: :boolean,
        required: false,
        default: false,
        doc: "Enable multiline matching where . matches newlines (default: false)"
      ],
      type: [
        type: {:or, [:string, nil]},
        required: false,
        default: nil,
        doc: "Ripgrep file type filter (e.g. \"py\", \"js\", \"rust\"). Ignored in grep fallback."
      ]
    ]

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2]

  alias Magus.Agents.Signals
  alias Magus.Sandbox.Orchestrator

  @timeout_ms 30_000
  @max_line_length 500

  def display_name, do: "Searching files..."

  def summarize_output(%{total_matches: 0}), do: "No matches"

  def summarize_output(%{total_matches: n, files_matched: f, truncated: true}),
    do: "#{n}+ matches in #{f} file#{if f != 1, do: "s"}"

  def summarize_output(%{total_matches: n, files_matched: f}),
    do: "#{n} match#{if n != 1, do: "es"} in #{f} file#{if f != 1, do: "s"}"

  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id, :user_id]) do
      {:ok, ctx} ->
        search_files(ctx.conversation_id, ctx.user_id, params, context)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp search_files(conversation_id, user_id, params, context) do
    pattern = params["pattern"]
    path = params["path"] || "/workspace"
    include = params["include"]
    max_results = params["max_results"] || 250
    output_mode = params["output_mode"] || "content"
    case_insensitive = params["case_insensitive"] || false
    context_before = params["context_before"]
    context_after = params["context_after"]
    ctx_lines = params["context"]
    multiline = params["multiline"] || false
    type = params["type"]

    # Apply shorthand context if individual values not set
    context_before = context_before || ctx_lines
    context_after = context_after || ctx_lines

    Signals.emit_tool_progress(context, :searching, %{
      message: "Searching for \"#{String.slice(pattern, 0..40)}\"..."
    })

    opts = %{
      pattern: pattern,
      path: path,
      include: include,
      max_results: max_results,
      output_mode: output_mode,
      case_insensitive: case_insensitive,
      context_before: context_before,
      context_after: context_after,
      multiline: multiline,
      type: type
    }

    rg_cmd = build_rg_command(opts)
    grep_cmd = build_grep_fallback_command(opts)
    # Use rg directly (installed in sandbox Docker image), fall back to grep if missing
    command = "if which rg >/dev/null; then #{rg_cmd}; else #{grep_cmd}; fi"

    exec_opts = [
      timeout_ms: @timeout_ms,
      working_dir: "/workspace",
      description: "file search",
      user_id: user_id
    ]

    case Orchestrator.exec_command(conversation_id, command, exec_opts) do
      {:ok, %{stdout: stdout, stderr: stderr}} ->
        stdout = stdout || ""
        stderr = stderr || ""

        cond do
          String.trim(stdout) != "" ->
            parse_output(stdout, output_mode, max_results)

          String.contains?(stderr, "rg:") or String.contains?(stderr, "grep:") ->
            {:ok, %{error: "Search failed: #{stderr}"}}

          true ->
            empty_result(output_mode)
        end

      {:error, :not_configured, _} ->
        {:ok, %{error: "Sandbox not configured.", hint: "The sandbox service is not available."}}

      {:error, _type, details} ->
        {:ok, %{error: inspect(details)}}
    end
  end

  @doc false
  def build_rg_command(opts) do
    parts = ["rg", "--max-columns", "#{@max_line_length}"]

    parts =
      case opts.output_mode do
        "files_with_matches" -> parts ++ ["--files-with-matches"]
        "count" -> parts ++ ["--count"]
        _ -> parts ++ ["--line-number"]
      end

    parts = if opts[:case_insensitive], do: parts ++ ["--ignore-case"], else: parts
    parts = if opts[:multiline], do: parts ++ ["--multiline", "--multiline-dotall"], else: parts

    parts =
      if opts.output_mode == "content" do
        parts =
          if opts[:context_before], do: parts ++ ["-B", "#{opts[:context_before]}"], else: parts

        if opts[:context_after], do: parts ++ ["-A", "#{opts[:context_after]}"], else: parts
      else
        parts
      end

    parts = if opts[:include], do: parts ++ ["--glob", shell_escape(opts[:include])], else: parts
    parts = if opts[:type], do: parts ++ ["--type", shell_escape(opts[:type])], else: parts

    parts = parts ++ ["--", shell_escape(opts.pattern), shell_escape(opts.path)]
    "#{Enum.join(parts, " ")} | head -n #{opts.max_results + 1}"
  end

  @doc false
  def build_grep_fallback_command(opts) do
    flags =
      case opts.output_mode do
        "files_with_matches" -> "-rl"
        "count" -> "-rc"
        _ -> "-rn"
      end

    parts = ["grep #{flags}"]

    parts = if opts[:case_insensitive], do: parts ++ ["-i"], else: parts

    parts =
      if opts[:include],
        do: parts ++ ["--include=#{shell_escape(opts[:include])}"],
        else: parts

    parts = parts ++ ["-- #{shell_escape(opts.pattern)} #{shell_escape(opts.path)}"]
    "#{Enum.join(parts, " ")} | head -n #{opts.max_results + 1}"
  end

  defp parse_output(stdout, "files_with_matches", max_results) do
    all_files =
      stdout
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    total = length(all_files)
    truncated = total > max_results
    files = Enum.take(all_files, max_results)

    {:ok,
     %{
       files: files,
       total_matches: total,
       files_matched: length(files),
       truncated: truncated
     }}
  end

  defp parse_output(stdout, "count", max_results) do
    all_counts =
      stdout
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&parse_count_line/1)

    total_entries = length(all_counts)
    truncated = total_entries > max_results
    counts = Enum.take(all_counts, max_results)
    total_matches = Enum.reduce(counts, 0, fn %{count: c}, acc -> acc + c end)
    files_matched = length(counts)

    {:ok,
     %{
       counts: counts,
       total_matches: total_matches,
       files_matched: files_matched,
       truncated: truncated
     }}
  end

  defp parse_output(stdout, _content_mode, max_results) do
    all_matches =
      stdout
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&parse_grep_line/1)

    total = length(all_matches)
    truncated = total > max_results
    matches = Enum.take(all_matches, max_results)
    files_matched = matches |> Enum.map(& &1.file) |> Enum.uniq() |> length()

    {:ok,
     %{
       matches: matches,
       total_matches: total,
       files_matched: files_matched,
       truncated: truncated
     }}
  end

  defp empty_result("files_with_matches"),
    do: {:ok, %{files: [], total_matches: 0, files_matched: 0, truncated: false}}

  defp empty_result("count"),
    do: {:ok, %{counts: [], total_matches: 0, files_matched: 0, truncated: false}}

  defp empty_result(_),
    do: {:ok, %{matches: [], total_matches: 0, files_matched: 0, truncated: false}}

  # Parse a grep/rg -n output line: "file:line:content"
  defp parse_grep_line(line) do
    case String.split(line, ":", parts: 3) do
      [file, line_num, content] ->
        case Integer.parse(line_num) do
          {num, ""} -> [%{file: file, line: num, content: String.trim_trailing(content)}]
          _ -> []
        end

      _ ->
        []
    end
  end

  # Parse a rg --count output line: "file:count"
  defp parse_count_line(line) do
    case String.split(line, ":", parts: 2) do
      [file, count_str] ->
        case Integer.parse(String.trim(count_str)) do
          {count, ""} -> [%{file: file, count: count}]
          _ -> []
        end

      _ ->
        []
    end
  end

  # Simple shell escaping: wrap in single quotes, escape existing single quotes
  defp shell_escape(str) do
    escaped = String.replace(str, "'", "'\\''")
    "'#{escaped}'"
  end
end
