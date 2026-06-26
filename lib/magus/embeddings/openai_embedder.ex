defmodule Magus.Embeddings.OpenAIEmbedder do
  @moduledoc """
  Production embedder adapter. Delegates to `Magus.Files.EmbeddingModel.embed_query/1`
  and synthesizes a `Magus.SuperBrain.Usage` struct so callers can record
  `MessageUsage` rows with `usage_type: :embedding`.

  Token counts from the upstream embedding API are not always exposed; we
  approximate via character count (`max(div(String.length(text), 4), 1)`).
  This is good enough for cost analytics; revisit if exact token counts
  become available.
  """

  @behaviour Magus.Embeddings.Embedder

  @impl true
  def embed(text, _opts) when is_binary(text) do
    case Magus.Files.EmbeddingModel.embed_query(text) do
      {:ok, embedding} when is_list(embedding) ->
        model_name = Magus.Files.EmbeddingModel.model()
        approx_tokens = max(div(String.length(text), 4), 1)

        usage = %Magus.SuperBrain.Usage{
          model_name: model_name,
          prompt_tokens: approx_tokens,
          completion_tokens: 0,
          total_tokens: approx_tokens,
          cached_tokens: 0,
          input_cost: Decimal.new("0"),
          output_cost: Decimal.new("0"),
          total_cost: Decimal.new("0")
        }

        {:ok, %{embedding: embedding, usage: usage}}

      {:error, _} = err ->
        err
    end
  end
end
