defmodule Magus.SuperBrain.Retrieval.Ranker do
  @moduledoc """
  Composite retrieval ranker.

  Scores a candidate by multiplying six factors:

    * `similarity` from the vector store
    * trust tier multiplier (instruction/evidence/noise via Ontology)
    * graph weight (per-graph trust)
    * source weight (per-source trust)
    * recency decay (90-day half-life exponential)
    * neighborhood support (graph proximity boost)

  This is a pure module: no DB and no FalkorDB access. It is consumed by
  `Magus.SuperBrain.Retrieval` to rank fused candidates before returning
  them to the caller.
  """

  alias Magus.SuperBrain.Ontology

  @half_life_days 90

  @doc """
  Compute the composite score for a candidate.

  Expects a map with keys:

    * `:entity` with `:trust_tier`
    * `:similarity`
    * `:graph_weight`
    * `:source_weight`
    * `:latest_evidence_at` (DateTime or nil)
    * `:neighborhood_support`
  """
  def score(candidate) do
    tier_mult = Ontology.trust_tier_multiplier(candidate.entity.trust_tier)
    decay = recency_decay(candidate.latest_evidence_at)

    candidate.similarity *
      tier_mult *
      candidate.graph_weight *
      candidate.source_weight *
      decay *
      candidate.neighborhood_support
  end

  defp recency_decay(nil), do: 1.0

  defp recency_decay(%DateTime{} = dt) do
    days = DateTime.diff(DateTime.utc_now(), dt, :second) / 86_400.0
    :math.exp(-days / @half_life_days)
  end
end
