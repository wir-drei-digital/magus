defmodule Magus.Eval.SuperBrain.MetricsTest do
  use ExUnit.Case, async: true

  alias Magus.Eval.SuperBrain.Metrics

  defp result(id, expected, retrieved, opts) do
    %{
      id: id,
      meta: %{
        expected: expected,
        retrieved: retrieved,
        k: Keyword.get(opts, :k, 5),
        category: Keyword.get(opts, :category, "local_lookup"),
        supported: Keyword.get(opts, :supported, true)
      }
    }
  end

  test "supported aggregate is mean recall@k over supported cases" do
    results = [
      result(
        "a",
        [%{"name" => "Daniel", "type" => "person"}],
        [%{name: "Daniel", type: "person"}],
        []
      ),
      result(
        "b",
        [%{"name" => "Aurora", "type" => "project"}],
        [%{name: "Other", type: "concept"}],
        []
      )
    ]

    scored = Metrics.score(results, [])
    assert scored.aggregate == 0.5
  end

  test "known gaps are tracked separately and excluded from aggregate" do
    results = [
      result(
        "a",
        [%{"name" => "Daniel", "type" => "person"}],
        [%{name: "Daniel", type: "person"}],
        []
      ),
      result("gap", [%{"name" => "Alias", "type" => "person"}], [%{name: "Nope", type: "person"}],
        supported: false,
        category: "alias_resolution"
      )
    ]

    scored = Metrics.score(results, [])
    assert scored.aggregate == 1.0
    assert scored.known_gaps["alias_resolution"] == "0/1"
  end

  test "matching is case-insensitive on name and type" do
    results = [
      result(
        "a",
        [%{"name" => "daniel", "type" => "Person"}],
        [%{name: "Daniel", type: "person"}],
        []
      )
    ]

    assert Metrics.score(results, []).aggregate == 1.0
  end
end
