defmodule Magus.SuperBrain.Ontology do
  @moduledoc """
  Hybrid ontology: prescribed seed types + free-form subtypes.

  Iteration 1: seed types are fixed in code. Subtype promotion (night-cycle
  Reontologize pass) is deferred to iteration 2. Iteration 5 expands the
  canonical predicate set (temporal/identity/spatial/causal families) and
  adds five entity types.

  ## Atom safety

  Predicate classification accepts both atoms and binaries because the LLM
  emits string predicates while internal callers use atoms. We deliberately
  avoid `String.to_atom/1` on unbounded LLM input: atoms are never garbage
  collected and a verbose or adversarial LLM could exhaust the atom table
  and crash the BEAM. Instead, `classify_predicate/1`:

    * for canonical predicates, returns `{:canonical, atom}` (the atom is a
      module literal and therefore always exists);
    * for free-form input, tries `String.to_existing_atom/1` and returns
      `{:freeform, atom}` only when the atom is already known to the VM;
    * otherwise returns `{:freeform, binary}`, keeping the predicate as a
      string rather than minting new atoms.

  Callers that need a stable identifier should treat free-form predicates as
  binaries by default. Promotion to atom should happen explicitly at known
  safe sites, not implicitly inside this function.

  ## Trust tiers

  Tiers and their multipliers (applied at query time by
  `Magus.SuperBrain.Retrieval`):

    * `:instruction` (1.5): explicit user curation (insight callout,
      explicit memory, or a pinned fact). Highest trust.
    * `:evidence` (1.0): normal LLM-extracted facts of reasonable
      confidence.
    * `:noise` (0.2): low-confidence extractions or repeatedly contradicted
      claims.
  """

  @entity_types ~w(
    person organization project concept event location
    date document technology decision task fact
    role measurement goal resource identifier
  )a

  @canonical_predicates ~w(
    relates_to mentions supports contradicts derived_from
    updates extends derives
    precedes follows occurs_at
    is_a instance_of part_of
    located_in
    causes prevents enables
  )a

  @instruction_sources ~w(user_curated memory_explicit)a

  @low_confidence_threshold 0.25
  @instruction_confidence_threshold 0.9
  @contradiction_noise_threshold 3

  @doc "List of canonical seed entity types (17 in iter5)."
  def entity_types, do: @entity_types

  @doc "True when the given atom is one of the canonical entity types."
  def valid_entity_type?(type) when is_atom(type), do: type in @entity_types
  def valid_entity_type?(_), do: false

  @doc "List of canonical predicate atoms (18 in iter5)."
  def canonical_predicates, do: @canonical_predicates

  @doc "True when the given atom is a canonical predicate."
  def valid_predicate?(p) when is_atom(p), do: p in @canonical_predicates
  def valid_predicate?(_), do: false

  @doc """
  Classifies a predicate as canonical or free-form.

  Returns `{:canonical, atom}` for known predicates and `{:freeform, term}`
  otherwise. Free-form results are atoms only when the atom already exists
  in the VM; unknown strings stay as binaries to avoid atom-exhaustion DoS.
  """
  def classify_predicate(p) when is_atom(p) do
    if p in @canonical_predicates, do: {:canonical, p}, else: {:freeform, p}
  end

  def classify_predicate(p) when is_binary(p) do
    try do
      atom = String.to_existing_atom(p)

      if atom in @canonical_predicates,
        do: {:canonical, atom},
        else: {:freeform, atom}
    rescue
      ArgumentError -> {:freeform, p}
    end
  end

  @doc """
  Computes the trust tier for an extracted fact.

  Tiers:

    * `:instruction` - high-confidence, explicitly curated by the user
      (insight callout or explicit memory). Scored above ordinary evidence.
    * `:evidence` - normal LLM-extracted facts of reasonable confidence.
    * `:noise` - low-confidence extractions or repeatedly contradicted
      claims. Should be down-weighted in retrieval.

  Options:

    * `:source` - one of `#{inspect(@instruction_sources)}` to mark
      explicit instruction, otherwise treated as LLM extraction. Default
      `:llm_extract`.
    * `:contradiction_count` - integer count of times this fact has been
      contradicted by other extractions. Default `0`.
  """
  def compute_trust_tier(confidence, opts) when is_number(confidence) and is_list(opts) do
    source = Keyword.get(opts, :source, :llm_extract)
    contradictions = Keyword.get(opts, :contradiction_count, 0)

    cond do
      contradictions >= @contradiction_noise_threshold ->
        :noise

      confidence < @low_confidence_threshold ->
        :noise

      source in @instruction_sources and confidence >= @instruction_confidence_threshold ->
        :instruction

      true ->
        :evidence
    end
  end

  @doc "Scoring multiplier applied to a retrieval score based on trust tier."
  def trust_tier_multiplier(:instruction), do: 1.5
  def trust_tier_multiplier(:evidence), do: 1.0
  def trust_tier_multiplier(:noise), do: 0.2

  @doc """
  Map of predicates to their direct opposite.

  An aggregated `:RELATES_TO` edge is `contested` when the set of
  predicates observed for the same `(from_canonical, to_canonical)` pair
  contains both halves of an entry here. The map is intentionally
  symmetric so a single `Map.get/2` resolves either direction. Extend
  this set as more clearly opposed predicate pairs appear.
  """
  def contradicting_predicates do
    %{
      "supports" => "contradicts",
      "contradicts" => "supports",
      "precedes" => "follows",
      "follows" => "precedes",
      "causes" => "prevents",
      "prevents" => "causes"
    }
  end
end
