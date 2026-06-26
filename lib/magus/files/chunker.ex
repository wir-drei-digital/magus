defmodule Magus.Files.Chunker do
  @moduledoc """
  Handles fixed-size chunking of documents with overlap.
  Uses ~1000 tokens per chunk with 200 token overlap.
  """

  @default_chunk_size 1000
  @default_overlap 200

  @doc """
  Returns the default chunk size in tokens.
  """
  def default_chunk_size, do: @default_chunk_size

  @doc """
  Returns the default overlap in tokens.
  """
  def default_overlap, do: @default_overlap

  @doc """
  Chunks text into overlapping segments.
  Returns list of maps with :content, :position, and :token_count keys.

  ## Options
    * `:chunk_size` - Target tokens per chunk (default: #{@default_chunk_size})
    * `:overlap` - Overlap between chunks in tokens (default: #{@default_overlap})
  """
  def chunk_text(text, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)
    overlap = Keyword.get(opts, :overlap, @default_overlap)

    text = String.trim(text)

    if text == "" do
      []
    else
      do_chunk(text, chunk_size, overlap)
    end
  end

  defp do_chunk(text, chunk_size, overlap) do
    # Split into paragraphs first
    paragraphs = String.split(text, ~r/\n\n+/)

    {chunks, current, current_tokens} =
      Enum.reduce(paragraphs, {[], "", 0}, fn para, {chunks, current, current_tokens} ->
        para = String.trim(para)
        para_tokens = estimate_tokens(para)

        cond do
          # Skip empty paragraphs
          para == "" ->
            {chunks, current, current_tokens}

          # Current chunk + paragraph fits within target size
          current_tokens + para_tokens <= chunk_size ->
            new_content = join_text(current, para)
            {chunks, new_content, current_tokens + para_tokens}

          # Paragraph alone exceeds chunk size - split it
          para_tokens > chunk_size ->
            # Flush current chunk if any
            chunks = maybe_add_chunk(chunks, current, current_tokens)
            # Split large paragraph by sentences
            sentence_chunks = chunk_large_text(para, chunk_size, overlap)
            {chunks ++ sentence_chunks, "", 0}

          # Need to start new chunk with overlap
          true ->
            overlap_text = get_overlap_text(current, overlap)
            overlap_tokens = estimate_tokens(overlap_text)
            chunks = maybe_add_chunk(chunks, current, current_tokens)
            new_content = join_text(overlap_text, para)
            {chunks, new_content, overlap_tokens + para_tokens}
        end
      end)

    # Add remaining content
    chunks = maybe_add_chunk(chunks, current, current_tokens)

    # Add position indexes
    chunks
    |> Enum.with_index()
    |> Enum.map(fn {{content, token_count}, position} ->
      %{content: content, position: position, token_count: token_count}
    end)
  end

  defp chunk_large_text(text, chunk_size, overlap) do
    # Split by sentences
    sentences =
      text
      |> String.split(~r/(?<=[.!?])\s+/)
      |> Enum.filter(&(String.trim(&1) != ""))

    {chunks, current, current_tokens} =
      Enum.reduce(sentences, {[], "", 0}, fn sentence, {chunks, current, current_tokens} ->
        sentence_tokens = estimate_tokens(sentence)

        cond do
          # Sentence fits in current chunk
          current_tokens + sentence_tokens <= chunk_size ->
            new_content = join_text(current, sentence)
            {chunks, new_content, current_tokens + sentence_tokens}

          # Single sentence exceeds chunk size - split by words
          sentence_tokens > chunk_size and current == "" ->
            word_chunks = chunk_by_words(sentence, chunk_size, overlap)
            {chunks ++ word_chunks, "", 0}

          # Need to start new chunk
          true ->
            overlap_text = get_overlap_text(current, overlap)
            overlap_tokens = estimate_tokens(overlap_text)
            chunks = maybe_add_chunk(chunks, current, current_tokens)
            new_content = join_text(overlap_text, sentence)
            {chunks, new_content, overlap_tokens + sentence_tokens}
        end
      end)

    maybe_add_chunk(chunks, current, current_tokens)
  end

  defp chunk_by_words(text, chunk_size, overlap) do
    words = String.split(text)

    {chunks, current_words, current_tokens} =
      Enum.reduce(words, {[], [], 0}, fn word, {chunks, current_words, current_tokens} ->
        word_tokens = estimate_tokens(word)

        if current_tokens + word_tokens <= chunk_size do
          {chunks, current_words ++ [word], current_tokens + word_tokens}
        else
          current_text = Enum.join(current_words, " ")
          chunks = maybe_add_chunk(chunks, current_text, current_tokens)

          # Get overlap from end of current chunk
          overlap_word_count = div(overlap * 4, 3)
          overlap_words = Enum.take(current_words, -overlap_word_count)
          overlap_text = Enum.join(overlap_words, " ")
          overlap_tokens = estimate_tokens(overlap_text)

          {chunks, overlap_words ++ [word], overlap_tokens + word_tokens}
        end
      end)

    current_text = Enum.join(current_words, " ")
    maybe_add_chunk(chunks, current_text, current_tokens)
  end

  defp get_overlap_text(text, target_tokens) do
    words = String.split(text)
    # Rough estimate: take enough words to get target_tokens
    # Using ~0.75 words per token as rough estimate for English
    word_count = div(target_tokens * 4, 3)
    overlap_words = Enum.take(words, -word_count)
    Enum.join(overlap_words, " ")
  end

  defp join_text("", new), do: new
  defp join_text(existing, new), do: existing <> "\n\n" <> new

  defp maybe_add_chunk(chunks, "", _), do: chunks
  defp maybe_add_chunk(chunks, content, token_count), do: chunks ++ [{content, token_count}]

  @doc """
  Estimates token count for text.
  Uses ~4 characters per token as rough estimate for English text.
  This is a simplified approximation - for production, consider using tiktoken.
  """
  def estimate_tokens(text) when is_binary(text) do
    # Rough estimate: ~4 characters per token for English text
    max(1, div(String.length(text), 4))
  end

  def estimate_tokens(_), do: 0
end
