defmodule Magus.Eval.ScoreboardTest do
  use ExUnit.Case, async: true

  alias Magus.Eval.Scoreboard

  setup do
    dir = Path.join(System.tmp_dir!(), "eval_sb_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "record/2 appends a JSONL row and returns the path", %{dir: dir} do
    run = %{
      benchmark: "coverage_smoke",
      aggregate: 0.8,
      config: %{model: "grok", limit: 5},
      cases: [%{id: "c1", correct?: true}],
      recorded_at: "2026-06-25T00:00:00Z"
    }

    assert {:ok, path} = Scoreboard.record(run, dir: dir)
    assert path == Path.join(dir, "coverage_smoke.jsonl")
    assert [line] = File.read!(path) |> String.split("\n", trim: true)
    assert %{"benchmark" => "coverage_smoke", "aggregate" => 0.8} = Jason.decode!(line)
  end

  test "record/2 appends, not overwrites", %{dir: dir} do
    base = %{benchmark: "coverage_smoke", config: %{}, cases: [], recorded_at: "t"}
    {:ok, _} = Scoreboard.record(Map.put(base, :aggregate, 0.1), dir: dir)
    {:ok, _} = Scoreboard.record(Map.put(base, :aggregate, 0.2), dir: dir)

    assert Scoreboard.recent("coverage_smoke", 10, dir: dir)
           |> Enum.map(& &1["aggregate"]) == [0.2, 0.1]
  end

  test "recent/3 skips corrupt lines instead of crashing", %{dir: dir} do
    File.mkdir_p!(dir)
    path = Path.join(dir, "coverage_smoke.jsonl")

    File.write!(path, ~s({"aggregate":0.1}) <> "\n")
    File.write!(path, "not valid json{\n", [:append])
    File.write!(path, ~s({"aggregate":0.2}) <> "\n", [:append])

    rows = Scoreboard.recent("coverage_smoke", 10, dir: dir)
    assert Enum.map(rows, & &1["aggregate"]) == [0.2, 0.1]
  end
end
