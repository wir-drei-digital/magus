defmodule Magus.Agents.Tools.Sandbox.SandboxHelpers do
  @moduledoc """
  Shared utility functions for sandbox tools.

  Provides helpers for fuzzy string matching (to tolerate line-number prefixes
  that models copy from `sandbox_read_file` output), unified diff generation,
  output truncation, and per-line length capping.
  """

  @line_prefix_re ~r/^\s*\d+\| /
  @context_lines 3
  @collapse_threshold 6

  # Curly quote pairs for normalization
  @left_double_curly "\u201C"
  @right_double_curly "\u201D"
  @left_single_curly "\u2018"
  @right_single_curly "\u2019"

  # ---------------------------------------------------------------------------
  # find_closest_match/2
  # ---------------------------------------------------------------------------

  @doc """
  Attempts to find `search` in `content`.

  Returns:
  - `{:exact, search}` if found verbatim
  - `{:fuzzy, line, candidate}` if found after normalization
  - `:no_match` if nothing close

  Normalization steps tried in order:
  1. Strip line-number prefixes (models copy these from `sandbox_read_file` output)
  2. Slide a window of search lines over content lines, matching after trimming
     leading whitespace per line
  """
  @spec find_closest_match(String.t(), String.t()) ::
          {:exact, String.t()} | {:fuzzy, non_neg_integer(), String.t()} | :no_match
  def find_closest_match(_content, ""), do: :no_match

  def find_closest_match(content, search) do
    if String.contains?(content, search) do
      {:exact, search}
    else
      fuzzy_match(content, search)
    end
  end

  # ---------------------------------------------------------------------------
  # strip_line_prefixes/1
  # ---------------------------------------------------------------------------

  @doc """
  Strips line-number prefixes (e.g. `"  1| "`, `" 10| "`) from each line of `text`.

  Only strips if at least 70% of lines have the prefix pattern. This avoids
  mangling content that happens to contain similar-looking sequences.
  """
  @spec strip_line_prefixes(String.t()) :: String.t()
  def strip_line_prefixes(""), do: ""

  def strip_line_prefixes(text) do
    lines = String.split(text, "\n")
    total = length(lines)

    prefix_count =
      Enum.count(lines, fn line -> Regex.match?(@line_prefix_re, line) end)

    if total > 0 and prefix_count / total >= 0.7 do
      lines
      |> Enum.map(fn line -> Regex.replace(@line_prefix_re, line, "", global: false) end)
      |> Enum.join("\n")
    else
      text
    end
  end

  # ---------------------------------------------------------------------------
  # build_unified_diff/3
  # ---------------------------------------------------------------------------

  @doc """
  Builds a unified diff between `old_content` and `new_content` using
  `List.myers_difference/2`.

  The diff is formatted as:
  ```
  --- filename
  +++ filename
   context line
  -deleted line
  +inserted line
  ```

  Equal sections longer than #{@collapse_threshold} lines show first
  #{@context_lines} and last #{@context_lines} with a summary in between.
  """
  @spec build_unified_diff(String.t(), String.t(), String.t()) :: String.t()
  def build_unified_diff(old_content, new_content, filename) do
    old_lines = String.split(old_content, "\n")
    new_lines = String.split(new_content, "\n")

    diff = List.myers_difference(old_lines, new_lines)

    body =
      diff
      |> Enum.flat_map(&format_diff_chunk/1)
      |> Enum.join("\n")

    "--- #{filename}\n+++ #{filename}\n#{body}"
  end

  # ---------------------------------------------------------------------------
  # truncate_output/2
  # ---------------------------------------------------------------------------

  @doc """
  Truncates `content` to `max_bytes` bytes, cutting at the last newline before
  the limit to avoid mid-line truncation.

  Returns:
  - `{:ok, content}` if the content is at or under `max_bytes`
  - `{:truncated, truncated_content, original_size}` if over the limit

  The truncated content includes a hint showing bytes shown vs total.
  """
  @spec truncate_output(String.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:truncated, String.t(), non_neg_integer()}
  def truncate_output(content, max_bytes) do
    size = byte_size(content)

    if size <= max_bytes do
      {:ok, content}
    else
      cut_at = find_cut_point(content, max_bytes)
      truncated = binary_part(content, 0, cut_at)
      hint = "\n... (showing #{cut_at} of #{size} bytes)"
      {:truncated, truncated <> hint, size}
    end
  end

  # ---------------------------------------------------------------------------
  # cap_line_length/2
  # ---------------------------------------------------------------------------

  @doc """
  Caps individual lines in `content` to `max_length` characters.

  Lines exceeding the limit are truncated and a hint `"... (N chars)"` is
  appended to indicate the original length.
  """
  @spec cap_line_length(String.t(), non_neg_integer()) :: String.t()
  def cap_line_length(content, max_length) do
    content
    |> String.split("\n")
    |> Enum.map(fn line -> cap_line(line, max_length) end)
    |> Enum.join("\n")
  end

  # ---------------------------------------------------------------------------
  # normalize_quotes/1
  # ---------------------------------------------------------------------------

  @doc """
  Normalizes curly/smart quotes to straight ASCII quotes.

  LLMs cannot output curly quotes, but files may contain them (from rich text
  editors, copied prose, etc.). This normalizes both sides for comparison.

  - \u201C / \u201D (left/right double curly) -> "
  - \u2018 / \u2019 (left/right single curly) -> '
  """
  @spec normalize_quotes(String.t()) :: String.t()
  def normalize_quotes(text) do
    text
    |> String.replace(@left_double_curly, "\"")
    |> String.replace(@right_double_curly, "\"")
    |> String.replace(@left_single_curly, "'")
    |> String.replace(@right_single_curly, "'")
  end

  @doc """
  Finds `search` in `content` with quote normalization.

  If the exact string isn't found, tries normalizing curly quotes to straight
  quotes on both sides. If a match is found that way, returns the actual
  substring from the file (preserving original curly quotes).

  Returns `{actual_string, :exact | :normalized}` or `:not_found`.
  """
  @spec find_with_quote_normalization(String.t(), String.t()) ::
          {String.t(), :exact | :normalized} | :not_found
  def find_with_quote_normalization(content, search) do
    cond do
      String.contains?(content, search) ->
        {search, :exact}

      true ->
        normalized_search = normalize_quotes(search)
        normalized_content = normalize_quotes(content)

        # Use String.split to find the match position in characters (not bytes),
        # since curly quotes are multi-byte but normalize to single-byte ASCII.
        case String.split(normalized_content, normalized_search, parts: 2) do
          [before, _after] ->
            char_pos = String.length(before)
            char_len = String.length(search)
            actual = String.slice(content, char_pos, char_len)
            {actual, :normalized}

          [_no_match] ->
            :not_found
        end
    end
  end

  # ---------------------------------------------------------------------------
  # strip_trailing_whitespace/1
  # ---------------------------------------------------------------------------

  @doc """
  Strips trailing whitespace from each line in `text`.

  Preserves line endings themselves. This helps match strings where the model
  omitted trailing spaces that exist in the file.
  """
  @spec strip_trailing_whitespace(String.t()) :: String.t()
  def strip_trailing_whitespace(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.join("\n")
  end

  # ---------------------------------------------------------------------------
  # apply_edit/4
  # ---------------------------------------------------------------------------

  @doc """
  Applies a search-and-replace edit with normalization.

  Tries matching in order:
  1. Exact match
  2. Quote-normalized match (curly -> straight quotes)
  3. Trailing-whitespace-stripped match

  When deleting text (new_string is empty), automatically removes a trailing
  newline after old_string to avoid leaving blank lines.

  Returns `{:ok, new_content, actual_old_string}` or `{:error, reason}`.
  """
  @spec apply_edit(String.t(), String.t(), String.t(), boolean()) ::
          {:ok, String.t(), String.t()} | {:error, :not_found | :multiple_matches, term()}
  def apply_edit(content, old_string, new_string, replace_all \\ false) do
    # Try matching strategies in order
    {actual_old, occurrences} =
      case count_matches(content, old_string) do
        n when n > 0 ->
          {old_string, n}

        0 ->
          # Try quote normalization
          case find_with_quote_normalization(content, old_string) do
            {actual, :normalized} -> {actual, count_matches(content, actual)}
            :not_found -> try_whitespace_stripped(content, old_string)
          end
      end

    cond do
      occurrences == 0 ->
        {:error, :not_found, nil}

      occurrences > 1 and not replace_all ->
        {:error, :multiple_matches, occurrences}

      true ->
        # Handle deletion trailing newline cleanup
        {effective_old, effective_new} =
          cleanup_deletion_newline(content, actual_old, new_string)

        new_content =
          if replace_all do
            String.replace(content, effective_old, effective_new)
          else
            do_replace_first(content, effective_old, effective_new)
          end

        replacements = if replace_all, do: occurrences, else: 1
        {:ok, new_content, %{actual_old: actual_old, replacements: replacements}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fuzzy_match(content, search) do
    # Step 1: strip line-number prefixes from the search string
    normalized_search = strip_line_prefixes(search)

    if normalized_search != search and String.contains?(content, normalized_search) do
      {:fuzzy, 0, normalized_search}
    else
      # Step 2: sliding-window match with leading whitespace trimmed per line
      sliding_window_match(content, normalized_search)
    end
  end

  defp sliding_window_match(content, search) do
    content_lines = String.split(content, "\n")
    search_lines = String.split(search, "\n")
    n_search = length(search_lines)
    n_content = length(content_lines)

    if n_search > n_content do
      :no_match
    else
      stripped_search = Enum.map(search_lines, &String.trim_leading/1)

      result =
        0..(n_content - n_search)
        |> Enum.find_value(fn start_idx ->
          window = Enum.slice(content_lines, start_idx, n_search)
          stripped_window = Enum.map(window, &String.trim_leading/1)

          if stripped_window == stripped_search do
            candidate = Enum.join(window, "\n")
            {start_idx, candidate}
          end
        end)

      case result do
        {line_idx, candidate} -> {:fuzzy, line_idx, candidate}
        nil -> :no_match
      end
    end
  end

  defp format_diff_chunk({:eq, lines}) when length(lines) > @collapse_threshold do
    first = Enum.take(lines, @context_lines) |> Enum.map(&" #{&1}")
    last = Enum.take(lines, -@context_lines) |> Enum.map(&" #{&1}")
    omitted = length(lines) - @context_lines * 2
    first ++ ["... (#{omitted} unchanged lines)"] ++ last
  end

  defp format_diff_chunk({:eq, lines}), do: Enum.map(lines, &" #{&1}")
  defp format_diff_chunk({:del, lines}), do: Enum.map(lines, &"-#{&1}")
  defp format_diff_chunk({:ins, lines}), do: Enum.map(lines, &"+#{&1}")

  defp find_cut_point(content, max_bytes) do
    # Find all newline positions up to max_bytes
    search_region = binary_part(content, 0, max_bytes)

    case :binary.matches(search_region, "\n") do
      [] ->
        # No newline found — cut at max_bytes
        max_bytes

      positions ->
        # Take the last newline position
        {pos, _len} = List.last(positions)
        pos
    end
  end

  defp cap_line(line, max_length) do
    len = String.length(line)

    if len > max_length do
      truncated = String.slice(line, 0, max_length)
      "#{truncated}... (#{len} chars)"
    else
      line
    end
  end

  defp count_matches(content, search) do
    length(String.split(content, search)) - 1
  end

  defp try_whitespace_stripped(content, old_string) do
    stripped_old = strip_trailing_whitespace(old_string)
    stripped_content = strip_trailing_whitespace(content)

    case count_matches(stripped_content, stripped_old) do
      0 ->
        {old_string, 0}

      _n ->
        # Find the actual string in the original content by locating it in stripped space
        # and extracting from the original at the same line positions
        case :binary.match(stripped_content, stripped_old) do
          {pos, _len} ->
            # Count lines before match in stripped content to find corresponding position
            before_stripped = binary_part(stripped_content, 0, pos)
            line_offset = length(String.split(before_stripped, "\n")) - 1

            # Extract the same number of lines from original content
            original_lines = String.split(content, "\n")
            search_line_count = length(String.split(old_string, "\n"))

            actual =
              original_lines
              |> Enum.slice(line_offset, search_line_count)
              |> Enum.join("\n")

            {actual, count_matches(content, actual)}

          :nomatch ->
            {old_string, 0}
        end
    end
  end

  # When deleting text (new_string is empty), if old_string doesn't end with \n
  # but the file has old_string followed by \n, remove the trailing newline too
  # to avoid leaving blank lines.
  defp cleanup_deletion_newline(content, old_string, new_string) do
    if new_string == "" and not String.ends_with?(old_string, "\n") and
         String.contains?(content, old_string <> "\n") do
      {old_string <> "\n", ""}
    else
      {old_string, new_string}
    end
  end

  defp do_replace_first(content, old_string, new_string) do
    case String.split(content, old_string, parts: 2) do
      [before, after_part] -> before <> new_string <> after_part
      [_no_match] -> content
    end
  end
end
