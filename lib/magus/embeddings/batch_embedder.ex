defmodule Magus.Embeddings.BatchEmbedder do
  @moduledoc """
  Behaviour for batched text embedders used by Super Brain extraction.

  Extraction-time embedding is a list-shaped operation: each Episode embeds
  the raw_text plus the names of every extracted entity in one or two API
  calls. Keeping a dedicated behaviour (separate from
  `Magus.Embeddings.Embedder` which only handles single-text retrieval
  embeddings) lets tests inject deterministic embeddings without standing
  up the broader file-chunking embedding surface.

  Production binds to `Magus.Embeddings.OpenAIBatchEmbedder`, which adapts
  `Magus.Files.EmbeddingModel` (OpenRouter text-embedding-3-small) with its
  built-in 100-item batching. Tests bind to a Mox mock
  (`Magus.Embeddings.BatchEmbedderMock`).

  ## Return shape

  Implementations return:

    * `embed_many/1`: `{:ok, [embedding]} | {:error, term()}` where the
      output list mirrors the input order and length.
    * `embed_one/1`: `{:ok, embedding} | {:error, term()}` for single
      strings (the Episode raw_text path).
  """

  @callback embed_many(texts :: [String.t()]) ::
              {:ok, [[float()]]} | {:error, term()}

  @callback embed_one(text :: String.t()) ::
              {:ok, [float()]} | {:error, term()}
end
