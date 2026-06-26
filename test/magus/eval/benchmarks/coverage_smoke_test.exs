defmodule Magus.Eval.Benchmarks.CoverageSmokeTest do
  use ExUnit.Case, async: true

  alias Magus.Eval.Benchmarks.CoverageSmoke

  test "name/0 and cases/2 load from the fixture" do
    assert CoverageSmoke.name() == "coverage_smoke"
    {:ok, dataset} = CoverageSmoke.load_dataset([])
    cases = CoverageSmoke.cases(dataset, [])
    assert length(cases) >= 3

    c = hd(cases)
    assert is_binary(c.id)
    assert is_binary(c.question)
    assert is_binary(c.gold)
    assert [%{role: role, text: t} | _] = c.ingest_items
    assert role in [:user, :assistant]
    assert is_binary(t)
  end

  test "score/2 is deterministic containment of gold in answer" do
    results = [
      %{id: "a", question: "q", gold: "Lisbon", answer: "You live in Lisbon.", meta: %{}},
      %{id: "b", question: "q", gold: "Lisbon", answer: "I am not sure.", meta: %{}}
    ]

    scored = CoverageSmoke.score(results, [])
    assert scored.aggregate == 0.5
    assert Enum.find(scored.per_case, &(&1.id == "a")).correct? == true
    assert Enum.find(scored.per_case, &(&1.id == "b")).correct? == false
  end

  test "score/2 normalizes case and whitespace" do
    results = [%{id: "a", question: "q", gold: "New York", answer: "it's new  york!", meta: %{}}]
    assert CoverageSmoke.score(results, []).aggregate == 1.0
  end
end
