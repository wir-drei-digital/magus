defmodule Magus.Eval.Benchmarks.GAIA do
  @moduledoc """
  GAIA agentic benchmark adapter (text-only validation tasks). Each task is sent
  as a question with empty ingest; the agent solves it with its tools. Scored by
  deterministic quasi-exact-match (no judge), with a per-level breakdown.
  """
  @behaviour Magus.Eval.Benchmark

  alias Magus.Eval.GaiaScore

  @impl true
  def name, do: "gaia"

  @impl true
  def load_dataset(opts), do: Magus.Eval.Benchmarks.GAIA.Loader.load(opts)

  @impl true
  def cases(dataset, _opts) do
    dataset
    |> Enum.filter(fn t -> (t["file_name"] || "") == "" end)
    |> Enum.map(fn t ->
      %{
        id: t["task_id"],
        question: t["Question"],
        gold: t["Final answer"],
        meta: %{level: t["Level"]},
        ingest_items: []
      }
    end)
  end

  @impl true
  def emit_hypotheses(results, path) do
    body =
      Enum.map_join(results, "\n", fn r ->
        Jason.encode!(%{task_id: r.id, model_answer: r.answer || ""})
      end)

    File.write!(path, body <> "\n")
    :ok
  end

  @impl true
  def score(results, _opts) do
    graded =
      Enum.map(results, fn r ->
        %{
          id: r.id,
          level: get_in(r, [:meta, :level]),
          correct?: GaiaScore.match?(r.answer || "", r.gold || "")
        }
      end)

    t = tally(graded)
    %{aggregate: t.aggregate, per_case: graded, per_level: t.per_level}
  end

  @doc "Pure aggregation over graded results."
  def tally(graded) do
    total = length(graded)
    correct = Enum.count(graded, & &1.correct?)

    per_level =
      graded
      |> Enum.group_by(& &1.level)
      |> Map.new(fn {level, items} ->
        c = Enum.count(items, & &1.correct?)
        n = length(items)
        {level, %{total: n, correct: c, accuracy: if(n == 0, do: 0.0, else: c / n)}}
      end)

    %{
      total: total,
      aggregate: if(total == 0, do: 0.0, else: correct / total),
      per_level: per_level
    }
  end
end
