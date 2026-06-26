defmodule Magus.Drafts.ProseMirrorConverter.NodeReplacer do
  @moduledoc """
  Performs surgical edits on ProseMirror JSON documents.

  Two replacement modes:

  ## Mode A: Text-based replacement (AI surgical edits)

  `replace_text/4` converts the JSON document to a deterministic markdown
  representation, performs string matching/replacement on the markdown,
  then converts the result back to JSON. This leverages the same proven
  `:binary.matches/2` approach as the old `ReplaceText` change, but
  operates on machine-generated (deterministic) markdown rather than
  user-written markdown.

  ## Mode B: Position-based replacement (user refine flow)

  `replace_at_positions/4` uses ProseMirror absolute positions (`from`/`to`)
  to locate the exact content to replace. This is the most robust path —
  no text matching needed, just structured tree operations using editor positions.
  """

  alias Magus.Drafts.ProseMirrorConverter

  # ---------------------------------------------------------------------------
  # Mode A: Text-based replacement
  # ---------------------------------------------------------------------------

  @doc """
  Replaces text in a ProseMirror JSON document using markdown-level matching.

  1. Converts the JSON doc to markdown via `to_markdown/1`
  2. Finds `old_text` in the markdown using `:binary.matches/2`
  3. Replaces the match and converts the full result back to JSON

  When `old_text` appears multiple times, `hint_line` (1-indexed) is used
  to pick the occurrence closest to that line number.

  Returns `{:ok, updated_json_doc}` or `{:error, reason}`.
  """
  @spec replace_text(map(), String.t(), String.t(), integer() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def replace_text(_doc, "", _new_text, _hint_line) do
    {:error, "old_text must not be empty"}
  end

  def replace_text(doc, old_text, new_text, hint_line) do
    markdown = ProseMirrorConverter.to_markdown(doc)

    case :binary.matches(markdown, old_text) do
      [] ->
        {:error, "text not found in document"}

      [{offset, length}] ->
        new_markdown = replace_at(markdown, offset, length, new_text)
        ProseMirrorConverter.from_markdown(new_markdown)

      matches when is_list(matches) ->
        if hint_line do
          {offset, length} = closest_match(markdown, matches, hint_line)
          new_markdown = replace_at(markdown, offset, length, new_text)
          ProseMirrorConverter.from_markdown(new_markdown)
        else
          {:error, "found #{length(matches)} occurrences; provide hint_line to disambiguate"}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Mode B: Position-based replacement
  # ---------------------------------------------------------------------------

  @doc """
  Replaces content at ProseMirror absolute positions `from`/`to`.

  Extracts the text at those positions from the JSON document, then
  replaces the containing block nodes with the new content (converted
  from markdown).

  This is used by the user refine flow where TipTap provides exact
  selection positions.

  Returns `{:ok, updated_json_doc}` or `{:error, reason}`.
  """
  @spec replace_at_positions(map(), integer(), integer(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def replace_at_positions(
        %{"type" => "doc", "content" => content} = _doc,
        from,
        to,
        new_text_markdown
      )
      when is_integer(from) and is_integer(to) and from < to do
    # Walk the document to find which top-level block nodes the from/to positions span
    {block_ranges, _pos} = map_positions_to_blocks(content, 0)

    # Find which blocks contain the from and to positions
    start_idx = find_block_index(block_ranges, from)
    end_idx = find_block_index(block_ranges, to - 1)

    if start_idx == nil or end_idx == nil do
      {:error, "positions out of range"}
    else
      # Convert the new markdown to ProseMirror JSON
      case ProseMirrorConverter.from_markdown(new_text_markdown) do
        {:ok, %{"type" => "doc", "content" => new_blocks}} ->
          # Splice: replace blocks[start_idx..end_idx] with new_blocks
          before = Enum.take(content, start_idx)
          after_blocks = Enum.drop(content, end_idx + 1)
          updated_content = before ++ new_blocks ++ after_blocks

          {:ok, %{"type" => "doc", "content" => updated_content}}

        {:error, reason} ->
          {:error, "failed to parse replacement markdown: #{inspect(reason)}"}
      end
    end
  end

  def replace_at_positions(_doc, _from, _to, _new_text) do
    {:error, "invalid positions"}
  end

  @doc """
  Extracts the plain text at ProseMirror positions `from`/`to` from a document.

  Used to get the selected text for sending to the LLM during refinement.
  """
  @spec extract_text_at_positions(map(), integer(), integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def extract_text_at_positions(%{"type" => "doc", "content" => content}, from, to)
      when is_integer(from) and is_integer(to) and from < to do
    {text, _pos} = collect_text_in_range(content, 0, from, to)
    {:ok, text}
  end

  def extract_text_at_positions(_, _, _), do: {:error, "invalid document or positions"}

  # ---------------------------------------------------------------------------
  # Private: text-based replacement helpers
  # ---------------------------------------------------------------------------

  defp replace_at(content, offset, length, new_text) do
    before = binary_part(content, 0, offset)
    after_text = binary_part(content, offset + length, byte_size(content) - offset - length)
    before <> new_text <> after_text
  end

  defp closest_match(content, matches, hint_line) do
    Enum.min_by(matches, fn {offset, _length} ->
      match_line = line_number_at_offset(content, offset)
      abs(match_line - hint_line)
    end)
  end

  defp line_number_at_offset(content, offset) do
    before = binary_part(content, 0, offset)
    1 + count_newlines(before)
  end

  defp count_newlines(binary) do
    binary |> :binary.matches("\n") |> length()
  end

  # ---------------------------------------------------------------------------
  # Private: position-based replacement helpers
  # ---------------------------------------------------------------------------

  # Maps each top-level block node to its ProseMirror position range.
  # ProseMirror positions count: +1 for entering a node, +1 for each character,
  # +1 for leaving a node. For simplicity at the block level, we track the
  # cumulative text length + structural overhead.
  defp map_positions_to_blocks(blocks, start_pos) do
    {ranges, pos} =
      Enum.reduce(blocks, {[], start_pos}, fn block, {acc, pos} ->
        # +1 for entering the block node
        inner_start = pos + 1
        inner_size = node_size(block) - 2
        # +1 for leaving the block node
        block_end = inner_start + inner_size + 1

        {acc ++ [{pos, block_end}], block_end}
      end)

    {ranges, pos}
  end

  defp find_block_index(block_ranges, position) do
    Enum.find_index(block_ranges, fn {start_pos, end_pos} ->
      position >= start_pos and position < end_pos
    end)
  end

  # Calculate the ProseMirror "size" of a node.
  # This is a simplified calculation that handles the common cases.
  defp node_size(%{"type" => "text", "text" => text}), do: String.length(text)

  defp node_size(%{"type" => "hardBreak"}), do: 1

  defp node_size(%{"type" => "image"}), do: 1

  defp node_size(%{"type" => "horizontalRule"}), do: 2

  defp node_size(%{"type" => _type, "content" => content}) do
    # 2 for open + close tags, plus the sum of children
    inner = Enum.reduce(content, 0, fn child, acc -> acc + node_size(child) end)
    2 + inner
  end

  defp node_size(%{"type" => _type}), do: 2

  # Collect text within a position range
  defp collect_text_in_range(nodes, pos, from, to) when is_list(nodes) do
    Enum.reduce(nodes, {"", pos}, fn node, {text_acc, current_pos} ->
      size = node_size(node)
      node_end = current_pos + size

      cond do
        # Node is entirely before the range
        node_end <= from ->
          {text_acc, node_end}

        # Node is entirely after the range
        current_pos >= to ->
          {text_acc, node_end}

        # Node overlaps with range — extract text
        true ->
          {node_text, _} = extract_node_text_in_range(node, current_pos, from, to)
          {text_acc <> node_text, node_end}
      end
    end)
  end

  defp extract_node_text_in_range(%{"type" => "text", "text" => text}, pos, from, to) do
    text_len = String.length(text)
    # Calculate which characters to include
    char_start = max(0, from - pos)
    char_end = min(text_len, to - pos)

    extracted =
      if char_start < char_end do
        String.slice(text, char_start, char_end - char_start)
      else
        ""
      end

    {extracted, pos + text_len}
  end

  defp extract_node_text_in_range(%{"type" => _type, "content" => content}, pos, from, to) do
    # +1 for the opening tag
    inner_pos = pos + 1
    {text, end_pos} = collect_text_in_range(content, inner_pos, from, to)
    # +1 for the closing tag
    {text, end_pos + 1}
  end

  defp extract_node_text_in_range(%{"type" => "hardBreak"}, pos, _from, _to) do
    {"\n", pos + 1}
  end

  defp extract_node_text_in_range(%{"type" => _}, pos, _from, _to) do
    {"", pos + node_size(%{"type" => "unknown"})}
  end
end
