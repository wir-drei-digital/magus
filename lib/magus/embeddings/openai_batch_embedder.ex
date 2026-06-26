defmodule Magus.Embeddings.OpenAIBatchEmbedder do
  @moduledoc """
  Production batch embedder. Adapts `Magus.Files.EmbeddingModel` so the
  Super Brain extraction pipeline can write Episode + Entity embeddings in
  one or two API calls per extraction.

  `Magus.Files.EmbeddingModel.embed/1` already handles 100-item batching
  internally and returns embeddings in input order; this module wraps it
  behind the `Magus.Embeddings.BatchEmbedder` behaviour so tests can
  substitute a deterministic Mox mock.
  """

  @behaviour Magus.Embeddings.BatchEmbedder

  @impl true
  def embed_many([]), do: {:ok, []}

  def embed_many(texts) when is_list(texts) do
    Magus.Files.EmbeddingModel.embed(texts)
  end

  @impl true
  def embed_one(text) when is_binary(text) do
    Magus.Files.EmbeddingModel.embed_query(text)
  end
end
