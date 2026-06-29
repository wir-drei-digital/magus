defmodule Magus.SuperBrain.GraphMetricsTest do
  use ExUnit.Case, async: true

  alias Magus.SuperBrain.GraphMetrics

  test "computes the metric set from raw inputs" do
    inputs = %{
      canonical_count: 10,
      relates_to_count: 8,
      isolated_count: 3,
      relates_to_fallback_count: 2,
      contested_count: 1,
      buckets: [
        %{distinct_name_count: 1},
        %{distinct_name_count: 3},
        %{distinct_name_count: 2}
      ]
    }

    m = GraphMetrics.compute(inputs)

    assert m["isolated_entity_rate"] == 0.3
    assert m["relates_to_fallback_rate"] == 0.25
    assert m["edges_per_entity"] == 0.8
    assert m["contested_edge_count"] == 1
    assert m["ambiguous_bucket_count"] == 2
  end

  test "is safe on an empty graph (no divide by zero)" do
    inputs = %{
      canonical_count: 0,
      relates_to_count: 0,
      isolated_count: 0,
      relates_to_fallback_count: 0,
      contested_count: 0,
      buckets: []
    }

    m = GraphMetrics.compute(inputs)
    assert m["isolated_entity_rate"] == 0.0
    assert m["relates_to_fallback_rate"] == 0.0
    assert m["edges_per_entity"] == 0.0
    assert m["ambiguous_bucket_count"] == 0
  end
end
