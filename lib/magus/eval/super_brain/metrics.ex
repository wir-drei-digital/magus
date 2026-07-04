defmodule Magus.Eval.SuperBrain.Metrics do
  @moduledoc """
  Pure retrieval-quality scoring for the `super_brain_retrieval` benchmark.

  Reads the expected entity set and the retrieved canonicals from each
  result's `meta` and computes recall@k, hit@k, and MRR by matching on
  normalized `(name, type)`. The headline `aggregate` is the mean recall@k
  over SUPPORTED cases only; known-gap (xfail) cases are reported separately
  so unimplemented capabilities never drag the number down.
  """

  @spec score([map()], keyword()) :: %{
          aggregate: float(),
          per_case: [map()],
          per_category: map(),
          known_gaps: map()
        }
  def score(results, _opts) do
    per_case = Enum.map(results, &grade/1)
    supported = Enum.filter(per_case, & &1.supported)

    %{
      aggregate: mean(Enum.map(supported, & &1.recall_at_k)),
      per_case: per_case,
      per_category: per_category(per_case),
      known_gaps: known_gaps(per_case)
    }
  end

  defp grade(%{id: id, meta: meta}) do
    target = get(meta, :target) || "entities"
    expected = normalize_expected(target, get(meta, :expected) || [])
    retrieved = normalize_retrieved(target, get(meta, :retrieved) || [])
    k = get(meta, :k) || 5
    topk = Enum.take(retrieved, k)
    recall = recall_at_k(expected, topk)

    %{
      id: id,
      category: get(meta, :category) || "unknown",
      supported: get(meta, :supported) == true,
      recall_at_k: recall,
      hit_at_k: hit_at_k(expected, topk),
      mrr: mrr(expected, retrieved),
      correct?: recall == 1.0
    }
  end

  defp normalize_expected("claims", list), do: Enum.map(list, &triple/1)
  defp normalize_expected(_entities, list), do: Enum.map(list, &normalize_one/1)

  defp normalize_retrieved("claims", list), do: Enum.map(list, &triple/1)
  defp normalize_retrieved(_entities, list), do: Enum.map(list, &normalize_one/1)

  defp triple(%{} = m),
    do: {down(get(m, :subject)), down(get(m, :predicate)), down(get(m, :object))}

  @doc false
  def recall_at_k([], _topk), do: 0.0

  def recall_at_k(expected, topk) do
    found = Enum.count(expected, fn e -> e in topk end)
    found / length(expected)
  end

  @doc false
  def hit_at_k(expected, topk), do: if(Enum.any?(expected, &(&1 in topk)), do: 1.0, else: 0.0)

  @doc false
  def mrr(expected, retrieved) do
    case Enum.find_index(retrieved, &(&1 in expected)) do
      nil -> 0.0
      idx -> 1.0 / (idx + 1)
    end
  end

  defp per_category(per_case) do
    per_case
    |> Enum.group_by(& &1.category)
    |> Map.new(fn {cat, items} ->
      {cat, mean(Enum.map(items, & &1.recall_at_k))}
    end)
  end

  defp known_gaps(per_case) do
    per_case
    |> Enum.reject(& &1.supported)
    |> Enum.group_by(& &1.category)
    |> Map.new(fn {cat, items} ->
      passing = Enum.count(items, & &1.correct?)
      {cat, "#{passing}/#{length(items)}"}
    end)
  end

  defp normalize_one(%{} = m) do
    name = get(m, :name)
    type = get(m, :type)
    {down(name), down(type)}
  end

  defp get(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp down(nil), do: nil
  defp down(s), do: s |> to_string() |> String.downcase()

  defp mean([]), do: 0.0
  defp mean(list), do: Enum.sum(list) / length(list)
end
