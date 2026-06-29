defmodule Magus.SuperBrain.EdgeAggregation do
  @moduledoc """
  Pure aggregation of Layer 1 RELATES_TO observations into a single Layer 2
  edge per `(from, to)` pair.

  Extracted from `BuildSuperFull` so the builder and the deterministic eval
  subject derive the same edge shape (predicate, predicate_breakdown,
  contested, trust_tier) from the same input. No I/O lives here; callers
  perform the FalkorDB writes.
  """

  alias Magus.SuperBrain.FalkorValues
  alias Magus.SuperBrain.Ontology

  # Trust-tier precedence for picking the strongest tier across a group.
  @tier_order %{"instruction" => 3, "evidence" => 2, "noise" => 1}

  @type observation :: %{
          from: term(),
          to: term(),
          predicate: String.t() | nil,
          confidence: number(),
          trust_tier: String.t() | nil,
          source_graph: String.t()
        }

  @doc "Aggregate L1 observations into one map per `(from, to)` pair."
  @spec aggregate([observation()]) :: [map()]
  def aggregate(observations) when is_list(observations) do
    observations
    |> Enum.group_by(fn o -> {o.from, o.to} end)
    |> Enum.map(fn {{from, to}, group} ->
      breakdown =
        group |> Enum.map(& &1.predicate) |> Enum.reject(&is_nil/1) |> Enum.frequencies()

      %{
        from: from,
        to: to,
        predicate: FalkorValues.most_common(Enum.map(group, & &1.predicate)),
        confidence: group |> Enum.map(& &1.confidence) |> Enum.max(fn -> 0.0 end),
        trust_tier: max_trust_tier(Enum.map(group, & &1.trust_tier)),
        source_graphs: group |> Enum.map(& &1.source_graph) |> Enum.uniq(),
        predicate_breakdown: breakdown,
        contested: contested?(breakdown),
        appearance_count: length(group)
      }
    end)
  end

  @doc "Strongest trust tier in the list, defaulting to \"evidence\"."
  @spec max_trust_tier([String.t() | nil]) :: String.t()
  def max_trust_tier(tiers) do
    tiers
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "evidence"
      list -> Enum.max_by(list, fn t -> Map.get(@tier_order, t, 0) end)
    end
  end

  @doc """
  True when the predicate-frequency map contains both halves of any opposed
  pair in `Ontology.contradicting_predicates/0`.
  """
  @spec contested?(map()) :: boolean()
  def contested?(breakdown) when is_map(breakdown) do
    contradicting = Ontology.contradicting_predicates()
    keys = Map.keys(breakdown)

    Enum.any?(keys, fn pred ->
      opposite = Map.get(contradicting, pred)
      opposite != nil and opposite in keys
    end)
  end
end
