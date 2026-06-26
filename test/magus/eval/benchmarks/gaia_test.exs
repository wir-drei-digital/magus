defmodule Magus.Eval.Benchmarks.GAIATest do
  use ExUnit.Case, async: true

  alias Magus.Eval.Benchmarks.GAIA

  defp fixture do
    Path.join([File.cwd!(), "test/support/fixtures/eval/gaia_sample.json"])
    |> File.read!()
    |> Jason.decode!()
  end

  test "name/0" do
    assert GAIA.name() == "gaia"
  end

  test "cases/2 keeps text-only tasks and maps to empty-ingest cases" do
    cases = GAIA.cases(fixture(), [])
    assert length(cases) == 2
    c = hd(cases)
    assert c.id == "t1"
    assert c.question == "What is 2 plus 2?"
    assert c.gold == "4"
    assert c.ingest_items == []
    assert c.meta == %{level: 1}
  end

  test "score/2 uses quasi-exact-match and reports per-level" do
    results = [
      %{id: "t1", question: "q", gold: "4", answer: "4", meta: %{level: 1}},
      %{id: "t2", question: "q", gold: "Paris", answer: "London", meta: %{level: 1}}
    ]

    s = GAIA.score(results, [])
    assert s.aggregate == 0.5
    assert s.per_level[1] == %{total: 2, correct: 1, accuracy: 0.5}
  end
end
