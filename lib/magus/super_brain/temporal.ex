defmodule Magus.SuperBrain.Temporal do
  @moduledoc """
  Pure temporal resolution over a list of accessible claims: validity
  windows, supersedence, and recency scoring.

  Callers apply the accessible-graph allow-list BEFORE calling in.
  Supersedence computed over exactly the claims the accessor can see is what
  makes the result correct per accessor: a superseder the accessor cannot
  read must not hide a claim they can read.

  Duck-typed: works on `Magus.SuperBrain.Claim` structs and plain maps alike,
  reading `id`, `subject_key`, `predicate`, `object_key`, `polarity`,
  `asserted_at`, `valid_from`, `valid_to`.

  No I/O and no clock reads: `now` is always injected so the eval can pin
  time. All DateTime ordering goes through `DateTime.compare/2`, never bare
  comparison operators (which compare struct terms).
  """

  alias Magus.SuperBrain.Ontology

  @recency_half_life_days 90
  @recency_floor 0.5

  @doc """
  Partitions `claims` into current and historic at `now`.

  Resolution order: validity partition first (expired and future claims go
  straight to historic), then supersedence over the in-window claims, then
  recency scoring on the survivors.

      %{
        current: [%{claim: claim, score_factors: %{recency: float}}],
        historic: [%{claim: claim, reason: :superseded | :expired | :future}]
      }

  `current` carries no ordering contract (callers rank by their own score).
  """
  def resolve(claims, opts) do
    now = Keyword.fetch!(opts, :now)

    {in_window, out_of_window} = partition_validity(claims, now)
    {kept, superseded} = drop_superseded(in_window)

    %{
      current:
        Enum.map(kept, fn c ->
          %{claim: c, score_factors: %{recency: recency_factor(c, now)}}
        end),
      historic: out_of_window ++ Enum.map(superseded, &%{claim: &1, reason: :superseded})
    }
  end

  @doc """
  Recency factor in `[0.5, 1.0]`:
  `0.5 + 0.5 * exp(-age_days * ln(2) / 90)`. The decaying half halves every
  90 days; the floor keeps recency a nudge, not a cliff. A nil `asserted_at`
  takes the floor (the column is nullable; every write path stamps it, but
  this module stays total).
  """
  def recency_factor(%{asserted_at: nil}, _now), do: @recency_floor

  def recency_factor(%{asserted_at: asserted_at}, now) do
    age_days = max(0, DateTime.diff(now, asserted_at)) / 86_400

    @recency_floor +
      (1.0 - @recency_floor) *
        :math.exp(-age_days * :math.log(2) / @recency_half_life_days)
  end

  # --- validity -------------------------------------------------------------

  defp partition_validity(claims, now) do
    claims
    |> Enum.reduce({[], []}, fn c, {in_w, out} ->
      case validity_reason(c, now) do
        nil -> {[c | in_w], out}
        reason -> {in_w, [%{claim: c, reason: reason} | out]}
      end
    end)
    |> then(fn {in_w, out} -> {Enum.reverse(in_w), Enum.reverse(out)} end)
  end

  defp validity_reason(c, now) do
    cond do
      c.valid_to != nil and DateTime.compare(c.valid_to, now) == :lt -> :expired
      c.valid_from != nil and DateTime.compare(c.valid_from, now) == :gt -> :future
      true -> nil
    end
  end

  # --- supersedence ----------------------------------------------------------

  # O(n^2) pairwise check; n is a retrieval working set (tens of claims), not
  # a corpus. A claim survives when no other in-window claim supersedes it.
  defp drop_superseded(claims) do
    Enum.split_with(claims, fn c -> not superseded_by_any?(c, claims) end)
  end

  defp superseded_by_any?(a, claims) do
    Enum.any?(claims, fn b -> b.id != a.id and supersedes?(b, a) end)
  end

  # Claim B supersedes claim A (both in-window, both accessible) when either
  # rule matches. See the temporal ranking spec, "Supersedence rules".
  defp supersedes?(b, a), do: value_change?(b, a) or polarity_flip?(b, a)

  # Value-change: same (subject_key, predicate), predicate single-valued,
  # BOTH :affirms, B newer. The :affirms restriction is load-bearing: a newer
  # negation of one object must not supersede an affirmation of another.
  defp value_change?(b, a) do
    a.subject_key == b.subject_key and
      a.predicate == b.predicate and
      a.polarity == :affirms and b.polarity == :affirms and
      Ontology.single_valued_predicate?(b.predicate) and
      newer?(b, a)
  end

  # Polarity flip: opposite polarity on the exact same triple, B newer. An
  # affirm-then-negate (or the reverse) is unambiguous for any predicate.
  defp polarity_flip?(b, a) do
    a.subject_key == b.subject_key and
      a.predicate == b.predicate and
      a.object_key == b.object_key and
      a.polarity != b.polarity and
      newer?(b, a)
  end

  # Total "newer than" order: asserted_at, then valid_from (nil sorts oldest
  # for both), then id descending. Ids are UUIDv7 (time-ordered), so the
  # final tie-break is deterministic and roughly insertion-ordered.
  defp newer?(b, a), do: compare_recency(b, a) == :gt

  defp compare_recency(b, a) do
    with :eq <- compare_nillable(b.asserted_at, a.asserted_at),
         :eq <- compare_nillable(b.valid_from, a.valid_from) do
      cond do
        b.id > a.id -> :gt
        b.id < a.id -> :lt
        true -> :eq
      end
    end
  end

  defp compare_nillable(nil, nil), do: :eq
  defp compare_nillable(nil, _), do: :lt
  defp compare_nillable(_, nil), do: :gt
  defp compare_nillable(x, y), do: DateTime.compare(x, y)
end
