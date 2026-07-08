defmodule Magus.SuperBrain.Dossier do
  @moduledoc """
  Pure aggregation of an entity's claims into a dossier: facts where the entity
  is the subject, claims where it is the object, and conflicts (opposite-polarity
  claims on the same triple). Groups are ordered newest-first by `asserted_at`.
  No I/O: callers fetch the accessible claims and pass them in. Claims may
  arrive tagged with a temporal `:status`; non-current claims are split into
  a `history` list instead of the fact groups.
  """

  @tier_order %{instruction: 3, evidence: 2, noise: 1}

  @spec build(String.t(), [map()]) :: %{
          facts: [map()],
          referenced_by: [map()],
          history: [map()],
          conflicts: [map()]
        }
  def build(entity_key, claims) do
    # Claims may carry :status from temporal resolution (:current |
    # :superseded | :expired | :future); absent status means current, so
    # pre-temporal callers keep their exact behavior.
    {current, historic} =
      Enum.split_with(claims, &(Map.get(&1, :status, :current) == :current))

    {as_subject, as_object} = Enum.split_with(current, &(&1.subject_key == entity_key))

    %{
      facts: group(as_subject, :object),
      referenced_by: group(as_object, :subject),
      history: history(historic),
      # Conflicts stay computed over ALL claims: a polarity flip is always
      # resolved by supersedence (one side wins), so a current-only conflict
      # scan would go permanently empty. The contested-triple signal stays,
      # and history explains which side lost and why.
      conflicts: conflicts(claims)
    }
  end

  # Non-current claims, newest-first, labeled with why they dropped out.
  # Only subject-side claims arrive tagged (see GetDossier), so the history
  # reads as the entity's own attribute history.
  defp history(historic) do
    historic
    |> Enum.sort_by(&(&1.asserted_at || ~U[1970-01-01 00:00:00Z]), {:desc, DateTime})
    |> Enum.map(fn c ->
      %{
        predicate: c.predicate,
        object_key: c.object_key,
        object_name: c.object_name,
        polarity: c.polarity,
        status: c.status,
        claim_text: c.claim_text,
        asserted_at: c.asserted_at
      }
    end)
  end

  defp group(claims, other_side) do
    claims
    |> Enum.group_by(fn c -> {c.predicate, other_key(c, other_side), c.polarity} end)
    |> Enum.map(fn {{predicate, other_key, polarity}, group} ->
      %{
        predicate: predicate,
        other_key: other_key,
        other_name: other_name(hd(group), other_side),
        polarity: polarity,
        texts: group |> Enum.map(& &1.claim_text) |> Enum.uniq(),
        evidence_count: length(group),
        trust_tier: max_tier(group),
        latest_asserted_at: group |> Enum.map(& &1.asserted_at) |> Enum.max(DateTime)
      }
    end)
    |> Enum.sort_by(& &1.latest_asserted_at, {:desc, DateTime})
  end

  defp conflicts(claims) do
    claims
    |> Enum.group_by(fn c -> {c.subject_key, c.predicate, c.object_key} end)
    |> Enum.filter(fn {_triple, group} ->
      group |> Enum.map(& &1.polarity) |> Enum.uniq() |> length() > 1
    end)
    |> Enum.map(fn {{s, p, o}, group} ->
      %{
        subject_key: s,
        predicate: p,
        object_key: o,
        texts: group |> Enum.map(& &1.claim_text) |> Enum.uniq()
      }
    end)
  end

  defp other_key(c, :object), do: c.object_key
  defp other_key(c, :subject), do: c.subject_key

  defp other_name(c, :object), do: c.object_name
  defp other_name(c, :subject), do: c.subject_name

  defp max_tier(group) do
    group
    |> Enum.map(& &1.trust_tier)
    |> Enum.max_by(fn t -> Map.get(@tier_order, t, 0) end, fn -> :evidence end)
  end
end
