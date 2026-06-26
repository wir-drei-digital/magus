defmodule Magus.Drafts.MarkdownResolver do
  @moduledoc """
  Maps rendered text selections back to raw markdown source lines.

  When a user selects text in a rendered markdown document, the browser
  returns visible text without markdown formatting (e.g. `bold` instead
  of `**bold**`). This module resolves such selections back to the
  corresponding raw markdown lines for surgical text replacement.
  """

  @doc """
  Resolves a rendered text selection to raw markdown for replacement.

  Strategy:

  1. If `selected_text` appears verbatim in `content`, return it as-is.
     This preserves sub-line precision for plain text or when the
     selection happens to match raw content (e.g. selecting "Title" from
     `# Title` correctly returns just "Title" — the heading prefix is
     outside the user's selection and `replace_draft_text` will only
     touch the matched substring).

  2. Otherwise, strip markdown formatting line-by-line and find the match
     in the stripped version. Returns the corresponding raw lines, which
     include markdown formatting the LLM should preserve.

  3. If nothing matches, returns `selected_text` unchanged (will error at
     `replace_draft_text`).
  """
  @spec resolve(String.t(), String.t(), integer() | nil) :: String.t()
  def resolve(content, selected_text, hint_line) do
    if String.contains?(content, selected_text) do
      selected_text
    else
      case find_raw_by_stripping(content, selected_text, hint_line) do
        {:ok, raw_section} -> raw_section
        :not_found -> selected_text
      end
    end
  end

  @doc """
  Strips markdown from content line-by-line, finds the selected text in the
  stripped version, and returns the corresponding raw lines.

  Uses `hint_line` (1-based) to disambiguate when the same stripped text
  appears at multiple locations.

  Two-pass match: first tries to find `selected_text` verbatim in the
  stripped content. If that fails (typical when the selection spans
  multiple blocks — TipTap's `textBetween` joins blocks with a single
  space, while the stripped markdown still has `\n\n` between blocks),
  falls back to a whitespace-normalized match: any run of whitespace in
  both the selection and the haystack collapses to a single space, then
  the byte offset in the normalized haystack is mapped back to a byte
  offset in the original. This catches multi-paragraph selections that
  would otherwise error out at `replace_draft_text` with
  "text not found in document".
  """
  @spec find_raw_by_stripping(String.t(), String.t(), integer() | nil) ::
          {:ok, String.t()} | :not_found
  def find_raw_by_stripping(content, selected_text, hint_line) do
    raw_lines = String.split(content, "\n")
    stripped_lines = strip_markdown_lines(raw_lines)
    stripped_content = Enum.join(stripped_lines, "\n")

    case :binary.matches(stripped_content, selected_text) do
      [] ->
        find_by_normalized_whitespace(stripped_content, selected_text, raw_lines, hint_line)

      [{offset, length}] ->
        extract_raw_lines(stripped_content, offset, length, raw_lines)

      matches ->
        {offset, length} = closest_match(matches, stripped_content, hint_line)
        extract_raw_lines(stripped_content, offset, length, raw_lines)
    end
  end

  # Whitespace-tolerant fallback. Builds a normalized projection of
  # `stripped_content` (every run of whitespace becomes a single space),
  # plus a mapping from each byte in the projection back to its source
  # byte offset, then matches against a similarly-normalized
  # `selected_text`. The mapping lets us recover the original
  # `[offset, length]` slice in `stripped_content` so `extract_raw_lines/4`
  # works unchanged.
  #
  # For ambiguous matches we just take the first occurrence — `hint_line`
  # disambiguation is intentionally skipped here because mapping a normalized
  # offset back to a source line number requires recounting newlines on each
  # candidate, and the verbatim-strip pass above already handles the common
  # multi-occurrence case. The fallback fires for selections that span block
  # boundaries, which are rarely duplicated.
  defp find_by_normalized_whitespace(stripped_content, selected_text, raw_lines, _hint_line) do
    {normalized, index_map} = normalize_with_map(stripped_content)
    needle = selected_text |> String.trim() |> normalize_whitespace()

    if needle == "" do
      :not_found
    else
      case :binary.match(normalized, needle) do
        :nomatch ->
          :not_found

        {n_offset, _} ->
          n_length = byte_size(needle)
          start_offset = Enum.at(index_map, n_offset)

          end_byte =
            case Enum.at(index_map, n_offset + n_length - 1) do
              nil -> byte_size(stripped_content)
              b -> b + 1
            end

          extract_raw_lines(stripped_content, start_offset, end_byte - start_offset, raw_lines)
      end
    end
  end

  # Build a normalized binary plus a list of original-byte indices, one entry
  # per normalized byte. Whitespace runs collapse to a single space; that
  # single space's index points at the first whitespace byte of the run.
  defp normalize_with_map(content) do
    bytes = :erlang.binary_to_list(content)
    {acc, map_acc} = collapse_whitespace(bytes, 0, false, [], [])
    {IO.iodata_to_binary(Enum.reverse(acc)), Enum.reverse(map_acc)}
  end

  defp collapse_whitespace([], _idx, _in_ws, acc, map_acc), do: {acc, map_acc}

  defp collapse_whitespace([byte | rest], idx, in_ws, acc, map_acc) do
    cond do
      whitespace_byte?(byte) and in_ws ->
        collapse_whitespace(rest, idx + 1, true, acc, map_acc)

      whitespace_byte?(byte) ->
        collapse_whitespace(rest, idx + 1, true, [?\s | acc], [idx | map_acc])

      true ->
        collapse_whitespace(rest, idx + 1, false, [byte | acc], [idx | map_acc])
    end
  end

  defp whitespace_byte?(byte), do: byte in [?\s, ?\t, ?\n, ?\r]

  defp normalize_whitespace(string) do
    String.replace(string, ~r/\s+/, " ")
  end

  @doc """
  Strips markdown formatting from a list of raw lines, preserving code blocks.

  Lines inside fenced code blocks (`` ``` ... ``` ``) are returned unchanged.
  """
  @spec strip_markdown_lines([String.t()]) :: [String.t()]
  def strip_markdown_lines(raw_lines) do
    {stripped, _in_fence} =
      Enum.map_reduce(raw_lines, false, fn line, in_fence ->
        cond do
          String.starts_with?(line, "```") -> {line, not in_fence}
          in_fence -> {line, in_fence}
          true -> {strip_markdown_inline(line), in_fence}
        end
      end)

    stripped
  end

  @doc """
  Strips common inline markdown formatting from a single line.

  Handles headings, blockquotes, list markers, bold, italic,
  strikethrough, inline code, links, and images. Preserves the
  visible text content so it matches what the browser renders.
  """
  @spec strip_markdown_inline(String.t()) :: String.t()
  def strip_markdown_inline(line) do
    line
    # Heading prefixes: # ## ### etc.
    |> String.replace(~r/^\#{1,6}\s+/, "")
    # Blockquote prefix (including nested: >> text)
    |> String.replace(~r/^(?:>\s?)+/, "")
    # Unordered list markers (with optional indentation)
    |> String.replace(~r/^\s*[-*+]\s+/, "")
    # Ordered list markers
    |> String.replace(~r/^\s*\d+\.\s+/, "")
    # Task list checkboxes: [x] or [ ]
    |> String.replace(~r/^\[[ xX]\]\s*/, "")
    # Images before links: ![alt](url) -> alt
    |> String.replace(~r/!\[([^\]]*)\]\([^)]+\)/, "\\1")
    # Links: [text](url) -> text
    |> String.replace(~r/\[([^\]]+)\]\([^)]+\)/, "\\1")
    # Bold: **text** or __text__
    |> String.replace(~r/\*\*(.+?)\*\*/, "\\1")
    |> String.replace(~r/__(.+?)__/, "\\1")
    # Strikethrough: ~~text~~
    |> String.replace(~r/~~(.+?)~~/, "\\1")
    # Italic: *text* or _text_ (after bold is already stripped)
    |> String.replace(~r/\*(.+?)\*/, "\\1")
    |> String.replace(~r/(?<!\w)_(.+?)_(?!\w)/, "\\1")
    # Inline code: `code` or ``code with `backtick` ``
    |> String.replace(~r/(`{1,3})(.+?)\1/, "\\2")
  end

  # -- Private helpers --------------------------------------------------------

  # Pick the match whose 1-based line number is closest to hint_line.
  # Falls back to the first match when hint_line is nil.
  defp closest_match(matches, _stripped_content, nil), do: List.first(matches)

  defp closest_match(matches, stripped_content, hint_line) do
    Enum.min_by(matches, fn {offset, _length} ->
      # hint_line is 1-based; count_newlines gives 0-based index, so add 1
      line = 1 + count_newlines(binary_part(stripped_content, 0, offset))
      abs(line - hint_line)
    end)
  end

  # Maps a byte range in stripped_content back to raw lines.
  # Uses 0-based line indices for Enum.slice (derived from newline counts).
  defp extract_raw_lines(stripped_content, offset, length, raw_lines) do
    before = binary_part(stripped_content, 0, offset)
    matched = binary_part(stripped_content, offset, length)

    # 0-based line indices for Enum.slice
    start_line = count_newlines(before)
    end_line = start_line + count_newlines(matched)

    raw_section =
      raw_lines
      |> Enum.slice(start_line..end_line//1)
      |> Enum.join("\n")

    {:ok, raw_section}
  end

  # Counts newline bytes in a binary. Used to convert byte offsets to line numbers.
  defp count_newlines(binary) do
    binary |> :binary.matches("\n") |> length()
  end
end
