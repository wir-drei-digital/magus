defmodule Magus.SuperBrain.Dossier do
  @moduledoc """
  Pure aggregation of an entity's claims into a dossier: facts where the entity
  is the subject, claims where it is the object, and conflicts (opposite-polarity
  claims on the same triple). Groups are ordered newest-first by `asserted_at`.
  No I/O: callers fetch the accessible claims and pass them in.
  """

  @tier_order %{instruction: 3, evidence: 2, noise: 1}

  @spec build(String.t(), [map()]) :: %{
          facts: [map()],
          referenced_by: [map()],
          conflicts: [map()]
        }
  def build(entity_key, claims) do
    {as_subject, as_object} = Enum.split_with(claims, &(&1.subject_key == entity_key))

    %{
      facts: group(as_subject, :object),
      referenced_by: group(as_object, :subject),
      conflicts: conflicts(as_subject ++ as_object)
    }
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
