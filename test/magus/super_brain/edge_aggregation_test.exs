defmodule Magus.SuperBrain.EdgeAggregationTest do
  use ExUnit.Case, async: true

  alias Magus.SuperBrain.EdgeAggregation

  defp obs(from, to, predicate, opts \\ []) do
    %{
      from: from,
      to: to,
      predicate: predicate,
      confidence: Keyword.get(opts, :confidence, 0.5),
      trust_tier: Keyword.get(opts, :trust_tier, "evidence"),
      source_graph: Keyword.get(opts, :source_graph, "brain:a")
    }
  end

  test "groups by (from, to) and picks the modal predicate" do
    edges = [
      obs("a", "b", "supports"),
      obs("a", "b", "supports", source_graph: "brain:b"),
      obs("a", "b", "mentions")
    ]

    assert [agg] = EdgeAggregation.aggregate(edges)
    assert agg.from == "a" and agg.to == "b"
    assert agg.predicate == "supports"
    assert agg.appearance_count == 3
    assert Enum.sort(agg.source_graphs) == ["brain:a", "brain:b"]
    assert agg.predicate_breakdown == %{"supports" => 2, "mentions" => 1}
    assert agg.contested == false
  end

  test "flags contested when opposing predicates co-occur" do
    edges = [obs("a", "b", "supports"), obs("a", "b", "contradicts")]
    assert [agg] = EdgeAggregation.aggregate(edges)
    assert agg.contested == true
  end

  test "max_trust_tier prefers instruction over evidence over noise" do
    assert EdgeAggregation.max_trust_tier(["evidence", "instruction", "noise"]) == "instruction"
    assert EdgeAggregation.max_trust_tier([nil, nil]) == "evidence"
  end

  test "max confidence wins" do
    edges = [
      obs("a", "b", "supports", confidence: 0.3),
      obs("a", "b", "supports", confidence: 0.9)
    ]

    assert [agg] = EdgeAggregation.aggregate(edges)
    assert agg.confidence == 0.9
  end
end
