defmodule Magus.Embeddings.Embedder do
  @moduledoc """
  Behaviour for text embedders consumed by the Super Brain retrieval stack.

  Production binds to `Magus.Embeddings.OpenAIEmbedder`, which adapts the
  shared `Magus.Files.EmbeddingModel` (OpenRouter text-embedding-3-small).
  Tests bind to a Mox mock (`Magus.Embeddings.EmbedderMock`) so retrieval
  paths can be exercised without hitting the network.

  ## Return shape

  Implementations return `{:ok, %{embedding: [float()], usage: Usage.t()}}`
  so callers can record unified `MessageUsage` rows with
  `usage_type: :embedding`. The `usage` field uses the shared
  `Magus.SuperBrain.Usage` struct.

  ## Why a separate behaviour from `Magus.Files.EmbeddingModel`?

  Retrieval-time embedding has a narrow, single-text shape. Keeping a
  dedicated behaviour lets tests inject deterministic embeddings without
  having to mock the broader file-chunking embedding surface that does
  batching and chunk processing.
  """

  @callback embed(text :: String.t(), opts :: keyword()) ::
              {:ok, %{embedding: [float()], usage: Magus.SuperBrain.Usage.t()}}
              | {:error, term()}
end
