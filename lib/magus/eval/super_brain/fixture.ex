defmodule Magus.Eval.SuperBrain.Fixture do
  @moduledoc """
  Parses the `fixture` object of a `super_brain_retrieval` case (decoded JSON
  with string keys) into a normalized struct that both eval subjects consume.
  The deterministic subject seeds these into the L2 super graph directly; the
  live subject seeds them into a Layer 1 graph and runs the real builder.
  """

  defstruct entities: [], edges: [], sources: [], claims: []

  @type t :: %__MODULE__{
          entities: [map()],
          edges: [map()],
          sources: [map()],
          claims: [map()]
        }

  @spec parse(map()) :: t()
  def parse(raw) when is_map(raw) do
    %__MODULE__{
      entities: Enum.map(Map.get(raw, "entities", []), &entity/1),
      edges: Enum.map(Map.get(raw, "edges", []), &edge/1),
      sources: Enum.map(Map.get(raw, "sources", []), &source/1),
      claims: Enum.map(Map.get(raw, "claims", []), &claim/1)
    }
  end

  defp entity(e) do
    %{
      key: Map.fetch!(e, "key"),
      name: Map.fetch!(e, "name"),
      type: Map.fetch!(e, "type"),
      normalized_subtype: Map.get(e, "normalized_subtype"),
      embedding: Map.get(e, "embedding", []),
      trust_tier: Map.get(e, "trust_tier", "evidence"),
      confidence: Map.get(e, "confidence", 0.8)
    }
  end

  defp edge(e) do
    %{
      from: Map.fetch!(e, "from"),
      to: Map.fetch!(e, "to"),
      predicate: Map.get(e, "predicate", "relates_to"),
      confidence: Map.get(e, "confidence", 0.8),
      trust_tier: Map.get(e, "trust_tier", "evidence")
    }
  end

  defp source(s) do
    %{
      entity: Map.fetch!(s, "entity"),
      resource_type: Map.fetch!(s, "resource_type"),
      resource_id: Map.fetch!(s, "resource_id")
    }
  end

  defp claim(c) do
    %{
      subject: Map.fetch!(c, "subject"),
      predicate: Map.fetch!(c, "predicate"),
      object: Map.fetch!(c, "object"),
      claim_text: Map.fetch!(c, "claim_text"),
      polarity: Map.get(c, "polarity", "affirms"),
      embedding: Map.get(c, "embedding"),
      trust_tier: Map.get(c, "trust_tier", "evidence"),
      confidence: Map.get(c, "confidence", 0.8)
    }
  end

  @doc "Expands a basis spec `%{\"hot\" => i}` to a `dim`-length one-hot vector."
  def expand_basis(%{"hot" => i}, dim \\ 1536) do
    List.duplicate(0.0, dim) |> List.replace_at(i, 1.0)
  end
end
