defmodule Magus.Eval.Benchmarks.ProfileDistillTest do
  use ExUnit.Case, async: true

  alias Magus.Eval.Benchmarks.ProfileDistill

  test "loads the dataset and builds cases with encoded seeds" do
    {:ok, dataset} = ProfileDistill.load_dataset([])
    cases = ProfileDistill.cases(dataset, [])

    assert length(cases) >= 6

    case_one = Enum.find(cases, &(&1.id == "contradiction_preference"))
    assert case_one.gold["gold_facts"] == ["The user prefers light mode", "The user uses VS Code"]

    [first_item | _] = case_one.ingest_items
    assert %{role: :user, text: json} = first_item
    assert %{"name" => _, "summary" => _} = Jason.decode!(json)
  end

  test "case_score is deterministic arithmetic" do
    assert ProfileDistill.case_score([true, true], [false], true) == 1.0
    assert ProfileDistill.case_score([true, false], [false], true) == 2 / 3
    assert ProfileDistill.case_score([true, true], [true], true) == 2 / 3
    assert ProfileDistill.case_score([true, true], [false], false) == 0.5
    assert ProfileDistill.case_score([], [], true) == 0.0
  end
end
