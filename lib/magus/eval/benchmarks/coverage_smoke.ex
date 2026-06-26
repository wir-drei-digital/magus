defmodule Magus.Eval.Benchmarks.CoverageSmoke do
  @moduledoc """
  Built-in deterministic reference benchmark. A small fixture of annotated
  conversations in which the user states a durable fact, then asks a question
  whose answer requires recalling it. Scored by normalized containment of the
  gold fact in the answer, so no judge and no external dataset are needed.
  Doubles as the seed of the internal coverage eval.
  """
  @behaviour Magus.Eval.Benchmark

  @impl true
  def name, do: "coverage_smoke"

  @impl true
  def load_dataset(_opts) do
    path = Path.join(:code.priv_dir(:magus), "eval/coverage_smoke/cases.json")

    with {:ok, body} <- File.read(path), {:ok, data} <- Jason.decode(body) do
      {:ok, data}
    end
  end

  @impl true
  def cases(dataset, _opts) do
    Enum.map(dataset, fn c ->
      %{
        id: c["id"],
        question: c["question"],
        gold: c["gold"],
        meta: %{},
        ingest_items:
          Enum.map(c["ingest_items"], fn i ->
            %{role: String.to_existing_atom(i["role"]), text: i["text"]}
          end)
      }
    end)
  end

  @impl true
  def emit_hypotheses(results, path) do
    body = Enum.map_join(results, "\n", fn r -> Jason.encode!(%{id: r.id, answer: r.answer}) end)
    File.write!(path, body <> "\n")
    :ok
  end

  @impl true
  def score(results, _opts) do
    per_case =
      Enum.map(results, fn r ->
        %{id: r.id, correct?: contains?(r.answer, r.gold), answer: r.answer, gold: r.gold}
      end)

    correct = Enum.count(per_case, & &1.correct?)
    aggregate = if per_case == [], do: 0.0, else: correct / length(per_case)
    %{aggregate: aggregate, per_case: per_case}
  end

  defp contains?(answer, gold), do: String.contains?(normalize(answer), normalize(gold))

  defp normalize(s) do
    s
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9 ]/u, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
