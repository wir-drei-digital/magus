defmodule Magus.SuperBrain.GraphMetrics do
  @moduledoc """
  Pure graph-shape metrics for a Layer 2 super graph, computed at build time
  and persisted to `SuperGraph.metrics`. No I/O: the caller gathers the raw
  counts (via FalkorDB Cypher) and passes them in.

  Metrics:

    * `isolated_entity_rate` - fraction of canonicals with NO `RELATES_TO`
      edge (APPEARS_IN is excluded; every canonical has at least one).
    * `relates_to_fallback_rate` - fraction of edges whose predicate is the
      generic `relates_to`.
    * `edges_per_entity` - `RELATES_TO` count divided by canonical count.
    * `contested_edge_count` - edges flagged `contested`.
    * `ambiguous_bucket_count` - `(type, normalized_subtype)` buckets holding
      more than one distinct name. A coarse upper bound on identity-resolution
      opportunity; intentionally noisy (phase 3 refines it with similarity).
  """

  @type inputs :: %{
          canonical_count: non_neg_integer(),
          relates_to_count: non_neg_integer(),
          isolated_count: non_neg_integer(),
          relates_to_fallback_count: non_neg_integer(),
          contested_count: non_neg_integer(),
          buckets: [%{distinct_name_count: non_neg_integer()}]
        }

  @spec compute(inputs()) :: %{String.t() => number()}
  def compute(inputs) do
    %{
      "isolated_entity_rate" => rate(inputs.isolated_count, inputs.canonical_count),
      "relates_to_fallback_rate" =>
        rate(inputs.relates_to_fallback_count, inputs.relates_to_count),
      "edges_per_entity" => rate(inputs.relates_to_count, inputs.canonical_count),
      "contested_edge_count" => inputs.contested_count,
      "ambiguous_bucket_count" =>
        Enum.count(inputs.buckets, fn b -> b.distinct_name_count > 1 end)
    }
  end

  defp rate(_numerator, 0), do: 0.0
  defp rate(numerator, denominator), do: numerator / denominator
end
