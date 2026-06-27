defmodule Magus.Eval.Benchmarks.SuperBrainRetrievalTest do
  use ExUnit.Case, async: true

  alias Magus.Eval.Benchmarks.SuperBrainRetrieval

  test "loads cases and carries the fixture in ingest_items" do
    {:ok, dataset} = SuperBrainRetrieval.load_dataset([])
    cases = SuperBrainRetrieval.cases(dataset, subject_kind: :deterministic)

    refute cases == []
    c = hd(cases)
    assert [%{role: :fixture, text: text}] = c.ingest_items
    assert {:ok, payload} = Jason.decode(text)
    assert Map.has_key?(payload, "fixture")
    assert Map.has_key?(payload, "query_embedding")
    assert Map.has_key?(c.meta, :expected)
  end

  test "subject_kind filters live-only cases out of deterministic runs" do
    {:ok, dataset} = SuperBrainRetrieval.load_dataset([])
    det = SuperBrainRetrieval.cases(dataset, subject_kind: :deterministic)

    # 4 cases include "deterministic" in subjects (local_lookup, contradiction, attribution, multi_hop)
    assert length(det) == 4
    refute Enum.any?(det, fn c -> c.meta.category == "same_name_fusion" end)
  end

  test "score delegates to Metrics shape" do
    results = [
      %{
        id: "x",
        meta: %{
          expected: [%{"name" => "Daniel", "type" => "person"}],
          retrieved: [%{name: "Daniel", type: "person"}],
          k: 5,
          category: "local_lookup",
          supported: true
        }
      }
    ]

    scored = SuperBrainRetrieval.score(results, [])
    assert scored.aggregate == 1.0
    assert Map.has_key?(scored, :known_gaps)
  end
end
