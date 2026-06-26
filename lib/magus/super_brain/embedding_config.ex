defmodule Magus.SuperBrain.EmbeddingConfig do
  @moduledoc """
  Single source of truth for the Super Brain embedding pipeline.

  Centralizes:

    * `dim/0` — the embedding dimension. All vector indexes, vector property
      writes, and KNN searches MUST agree on this value or FalkorDB will
      either reject the write or silently return zero hits.

    * `embedder/0` — the module implementing the embedder behaviour, read
      from application config (`:magus, :super_brain_embedder`). Centralized
      so tests can swap a deterministic mock without each caller fetching
      the env key directly.

    * `index_name/1` — the FalkorDB vector index label for a logical entity
      label. The dim is baked into the name so a future dimension change
      (e.g. swapping the embedder from OpenAI 1536-d to BGE 768-d or
      Voyage 3072-d) creates a fresh index instead of silently corrupting
      the existing one. Without this discipline, mixed-dim writes against
      the same index either error at the FalkorDB layer or — worse — go
      into a sized index that fails downstream KNN searches.

  When changing the dimension:

    1. Update `dim/0` here.
    2. Trigger a one-time rebuild per graph via `mix super_brain.rebuild`
       (or the equivalent code path). The next build will create a new
       index name automatically; old indexes become unreferenced and can
       be dropped manually.
  """

  @doc """
  Embedding dimension. Must match the vector size produced by the
  configured `embedder/0` AND any vector property already stored in
  FalkorDB. Changing this without rebuilding existing graphs will
  desync the index.
  """
  @spec dim() :: pos_integer()
  def dim, do: 1536

  @doc """
  Returns the configured embedder module (e.g. `Magus.Embeddings.OpenAIEmbedder`
  in prod, `Magus.Embeddings.EmbedderMock` in test).

  Raises if `:super_brain_embedder` is not configured. Fail-loud is intentional:
  silent fallbacks to a noop embedder would produce empty vectors that fail
  KNN search asymmetrically across deploys.
  """
  @spec embedder() :: module()
  def embedder, do: Application.fetch_env!(:magus, :super_brain_embedder)

  @doc """
  Logical name for the FalkorDB vector index covering `label`'s `embedding`
  property. The current embedding dim is baked into the name so a dim change
  yields a new index name and avoids dim-mixing corruption.

      iex> Magus.SuperBrain.EmbeddingConfig.index_name("Entity")
      "Entity__embedding__1536"

      iex> Magus.SuperBrain.EmbeddingConfig.index_name("CanonicalEntity")
      "CanonicalEntity__embedding__1536"

  Today this is consumed only by telemetry / logging callers as a stable
  identifier for the index. Wiring it as the FalkorDB label argument to
  `Magus.Graph.Vector.ensure_index/4` (and matching `knn_search/5`, node
  upserts, and MATCH queries) requires a coordinated rename plus a one-time
  graph rebuild per environment, so that adoption is deferred. The function
  is exported now so future call sites read a single source of truth.
  """
  @spec index_name(String.t()) :: String.t()
  def index_name(label) when is_binary(label) do
    "#{label}__embedding__#{dim()}"
  end
end
