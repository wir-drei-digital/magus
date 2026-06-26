defmodule Magus.Brain.BodyParser do
  @moduledoc """
  Pure functions that extract derived index data from a page body.

  Used by the Phase B rebuild workers (`RebuildPageLinks`,
  `RebuildPageSources`, `RebuildPageTags`) and — once it lands — by the
  Phase C `update_body` after-action pipeline. Keeping the extraction
  here means both code paths produce identical results.

  All extractors are forgiving: they return empty lists rather than
  raising on malformed input, and they skip patterns that look right
  syntactically but are semantically out of scope (e.g. `[[msg:...]]`
  message refs are skipped by `wikilinks/1`).
  """

  @doc """
  Returns the list of `[[Page Name]]` wikilink targets in the body,
  skipping `[[msg:...]]` message refs and stripping pipe aliases.

  ## Examples

      iex> Magus.Brain.BodyParser.wikilinks("See [[Other Page]] and [[Another|alias]]")
      ["Other Page", "Another"]

      iex> Magus.Brain.BodyParser.wikilinks("Message [[msg:abc-123|preview]]")
      []
  """
  @spec wikilinks(binary() | nil) :: [binary()]
  def wikilinks(nil), do: []

  def wikilinks(body) when is_binary(body) do
    Regex.scan(~r/\[\[([^\[\]]+)\]\]/, body)
    |> Enum.map(fn [_, inner] -> inner end)
    |> Enum.reject(&String.starts_with?(&1, "msg:"))
    |> Enum.map(fn inner ->
      case String.split(inner, "|", parts: 2) do
        [target, _alias] -> String.trim(target)
        [target] -> String.trim(target)
      end
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc """
  Returns the list of URLs found inside ` ```source ` fenced blocks
  in the body. Position in the returned list matches document order.

  Each fence is parsed with a minimal `key: value` parser. Fences
  without a `url:` key are skipped.

  ## Examples

      iex> body = ~s|```source\\nurl: https://example.com\\ntitle: Example\\n```|
      iex> Magus.Brain.BodyParser.source_urls(body)
      ["https://example.com"]
  """
  @spec source_urls(binary() | nil) :: [binary()]
  def source_urls(nil), do: []

  def source_urls(body) when is_binary(body) do
    Regex.scan(~r/```source\s*\n(.*?)```/s, body)
    |> Enum.map(fn [_, fence_body] -> extract_url(fence_body) end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Returns the deduplicated list of file ids referenced by
  `magus://file/<id>` (attachment links) and `magus://image/<id>`
  (image embeds) in the body. Both UUID v4 (36 chars, hyphenated) and
  ULID-style (26 alphanumeric) ids are accepted, matching what
  `Magus.Brain.BlockSerializer.to_markdown/1` emits.

  Order matches first occurrence in the body. Callers resolve files
  from the body so the rendered markdown is the single source of truth.

  ## Examples

      iex> body = "See [📎 spec](magus://file/11111111-1111-1111-1111-111111111111) and ![](magus://image/22222222-2222-2222-2222-222222222222)"
      iex> Magus.Brain.BodyParser.file_ids(body)
      ["11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"]

      iex> Magus.Brain.BodyParser.file_ids(nil)
      []
  """
  @spec file_ids(binary() | nil) :: [binary()]
  def file_ids(nil), do: []

  def file_ids(body) when is_binary(body) do
    ~r/magus:\/\/(?:file|image)\/([0-9a-f-]{36}|[0-9a-z]{26})/i
    |> Regex.scan(body)
    |> Enum.map(fn [_, id] -> id end)
    |> Enum.uniq()
  end

  @doc """
  Returns inline `#tag` occurrences in the body, normalized via
  `Magus.Brain.Frontmatter.normalize_tag/1`. Excludes tags inside code
  fences (a body of ` ```\\n#not_a_tag\\n``` ` yields no tags).

  ## Examples

      iex> Magus.Brain.BodyParser.inline_tags("This is #important and #ml stuff")
      ["important", "ml"]
  """
  @spec inline_tags(binary() | nil) :: [binary()]
  def inline_tags(nil), do: []

  def inline_tags(body) when is_binary(body) do
    body
    |> strip_code_fences()
    |> then(&Regex.scan(~r/(?:^|\s)#([\w-]+)/u, &1))
    |> Enum.map(fn [_, tag] -> Magus.Brain.Frontmatter.normalize_tag(tag) end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_url(fence_body) do
    case Regex.run(~r/^url\s*:\s*(.+?)\s*$/m, fence_body) do
      [_, url] -> url |> String.trim() |> unquote_string()
      _ -> nil
    end
  end

  defp unquote_string(~s("") <> _), do: nil
  defp unquote_string(<<"\"", rest::binary>>), do: String.trim_trailing(rest, "\"")
  defp unquote_string(s), do: s

  defp strip_code_fences(body) do
    Regex.replace(~r/```.*?```/s, body, "")
  end
end
