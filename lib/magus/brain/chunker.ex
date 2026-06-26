defmodule Magus.Brain.Chunker do
  @moduledoc """
  Paragraph-based text chunker for page bodies and source ingested
  content. Models after `Magus.Files.Chunker` but with smaller target
  size (~500 tokens) and no overlap — page bodies are short and we want
  chunks to align with paragraph boundaries for embedding-friendly
  granularity.

  Returns a list of `%{content, index, token_count}` maps suitable for
  bulk inserting into `brain_page_chunks` / `brain_source_chunks`.

  Token counts are estimated via `Magus.Files.Chunker.estimate_tokens/1`
  (the project-wide 4-chars-per-token approximation). Production may
  swap in tiktoken later; the chunker doesn't care.
  """

  @default_chunk_size 500

  @doc """
  Splits text into paragraph-aligned chunks, capped at `:chunk_size`
  tokens per chunk. Adjacent paragraphs are joined into a single chunk
  while the running total fits; a single oversized paragraph spills
  into its own chunk (we don't split mid-paragraph).

  ## Options

    * `:chunk_size` (default: 500) — target tokens per chunk
    * `:strip_frontmatter` (default: true) — strip a leading YAML
      `---`-delimited frontmatter block before chunking so it doesn't
      pollute semantic-search embeddings. The first chunk of a page
      with a 5-line frontmatter would otherwise be dominated by
      metadata.

  Returns `[]` for nil or empty input.
  """
  @spec chunk(binary() | nil, keyword()) :: [
          %{content: binary(), index: integer(), token_count: integer()}
        ]
  def chunk(text, opts \\ [])
  def chunk(nil, _opts), do: []
  def chunk("", _opts), do: []

  def chunk(text, opts) when is_binary(text) do
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)
    strip_frontmatter = Keyword.get(opts, :strip_frontmatter, true)

    text
    |> maybe_strip_frontmatter(strip_frontmatter)
    |> String.trim()
    |> case do
      "" ->
        []

      trimmed ->
        trimmed
        |> split_paragraphs()
        |> Enum.reduce({[], "", 0}, fn para, {chunks, current, current_tokens} ->
          para_tokens = estimate(para)

          cond do
            current == "" ->
              {chunks, para, para_tokens}

            current_tokens + para_tokens <= chunk_size ->
              {chunks, current <> "\n\n" <> para, current_tokens + para_tokens}

            true ->
              {[{current, current_tokens} | chunks], para, para_tokens}
          end
        end)
        |> flush_final()
        |> Enum.reverse()
        |> Enum.with_index()
        |> Enum.map(fn {{content, tokens}, idx} ->
          %{content: content, index: idx, token_count: tokens}
        end)
    end
  end

  defp maybe_strip_frontmatter(text, false), do: text

  defp maybe_strip_frontmatter(text, true) do
    case Magus.Brain.Frontmatter.parse(text) do
      {_matter, body_without_frontmatter} when is_binary(body_without_frontmatter) ->
        body_without_frontmatter

      _ ->
        text
    end
  end

  defp split_paragraphs(text) do
    text
    |> String.split(~r/\n{2,}/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp flush_final({chunks, "", _}), do: chunks
  defp flush_final({chunks, current, tokens}), do: [{current, tokens} | chunks]

  defp estimate(text), do: Magus.Files.Chunker.estimate_tokens(text)
end
