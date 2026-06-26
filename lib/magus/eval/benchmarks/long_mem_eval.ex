defmodule Magus.Eval.Benchmarks.LongMemEval do
  @moduledoc """
  LongMemEval-S memory benchmark adapter. Each question's haystack sessions are
  replayed (chronologically) as ingest turn-pairs so the agent must answer from
  recalled memory. Scored by the Elixir Judge, with an abstention path for `_abs`
  questions and a per-ability breakdown.
  """
  @behaviour Magus.Eval.Benchmark

  alias Magus.Eval.Judge

  @impl true
  def name, do: "longmemeval"

  @impl true
  def load_dataset(opts), do: Magus.Eval.Benchmarks.LongMemEval.Loader.load(opts)

  @impl true
  def cases(dataset, _opts) do
    Enum.map(dataset, fn e ->
      id = e["question_id"] || ""

      %{
        id: id,
        question: e["question"],
        gold: e["answer"],
        meta: %{question_type: e["question_type"], abstention: String.ends_with?(id, "_abs")},
        ingest_items: build_items(e)
      }
    end)
  end

  @impl true
  def emit_hypotheses(results, path) do
    body =
      Enum.map_join(results, "\n", fn r ->
        Jason.encode!(%{question_id: r.id, hypothesis: r.answer || ""})
      end)

    File.write!(path, body <> "\n")
    :ok
  end

  @impl true
  def score(results, opts) do
    graded =
      Enum.map(results, fn r ->
        abstention = get_in(r, [:meta, :abstention]) == true
        verdict = grade_one(r, abstention, opts)

        %{
          id: r.id,
          question_type: get_in(r, [:meta, :question_type]) || "unknown",
          abstention: abstention,
          correct?: verdict.correct?
        }
      end)

    t = tally(graded)
    %{aggregate: t.aggregate, per_case: graded, per_ability: t.per_ability}
  end

  @doc "Pure aggregation over graded results."
  def tally(graded) do
    total = length(graded)
    correct = Enum.count(graded, & &1.correct?)

    per_ability =
      graded
      |> Enum.group_by(& &1.question_type)
      |> Map.new(fn {ability, items} ->
        c = Enum.count(items, & &1.correct?)
        n = length(items)
        {ability, %{total: n, correct: c, accuracy: if(n == 0, do: 0.0, else: c / n)}}
      end)

    %{
      total: total,
      aggregate: if(total == 0, do: 0.0, else: correct / total),
      per_ability: per_ability
    }
  end

  defp grade_one(r, true, opts) do
    case Judge.grade(
           %{question: r.question, answer: r.answer},
           Keyword.put(opts, :mode, :abstention)
         ) do
      {:ok, v} -> v
      {:error, _} -> %{correct?: false}
    end
  end

  defp grade_one(r, false, opts) do
    case Judge.grade(%{question: r.question, answer: r.answer, gold: r.gold}, opts) do
      {:ok, v} -> v
      {:error, _} -> %{correct?: false}
    end
  end

  defp build_items(e) do
    sessions = e["haystack_sessions"] || []
    dates = e["haystack_dates"] || []

    # Sort sessions chronologically. haystack_dates are ISO 8601 (YYYY-MM-DD),
    # so a lexicographic string sort is the correct chronological order.
    sessions
    |> Enum.with_index()
    |> Enum.sort_by(fn {_session, i} -> Enum.at(dates, i) || "" end)
    |> Enum.flat_map(fn {session, _i} ->
      session
      |> Enum.map(fn t -> %{role: role(t["role"]), text: t["content"]} end)
      |> Enum.filter(&(&1.role != nil and is_binary(&1.text)))
    end)
  end

  defp role("user"), do: :user
  defp role("assistant"), do: :assistant
  defp role(_), do: nil
end
