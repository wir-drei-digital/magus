defmodule Magus.Eval.Benchmarks.SuperBrainRetrieval do
  @moduledoc """
  Retrieval-quality benchmark for the Layer 2 super graph. Each case carries a
  graph fixture (entities, edges, sources) plus an authored query embedding;
  the subject seeds the fixture and runs `Retrieval.search`, and `score/2`
  computes recall@k / hit@k / MRR against the expected entity set.

  The fixture rides in `ingest_items` (a single `:fixture`-role item) because
  the `Runner` only passes `ingest_items` to the subject; `meta` carries the
  scoring inputs (`expected/category/k/supported`). `cases/2` filters by
  `opts[:subject_kind]` so live-only cases (e.g. real fusion) are excluded
  from deterministic runs.
  """
  @behaviour Magus.Eval.Benchmark

  alias Magus.Eval.SuperBrain.Metrics

  @impl true
  def name, do: "super_brain_retrieval"

  @impl true
  def load_dataset(_opts) do
    path = Path.join(:code.priv_dir(:magus), "eval/super_brain_retrieval/cases.json")

    with {:ok, body} <- File.read(path), {:ok, data} <- Jason.decode(body) do
      {:ok, data}
    end
  end

  @impl true
  def cases(dataset, opts) do
    kind = opts[:subject_kind]

    dataset
    |> Enum.filter(&applies?(&1, kind))
    |> Enum.map(&to_case/1)
  end

  @impl true
  def emit_hypotheses(results, path) do
    body =
      Enum.map_join(results, "\n", fn r ->
        Jason.encode!(%{id: r.id, retrieved: get_in(r, [:meta, :retrieved]) || []})
      end)

    File.write!(path, body <> "\n")
    :ok
  end

  @impl true
  def score(results, opts), do: Metrics.score(results, opts)

  # A case applies when its `subjects` list includes the running kind. With no
  # `subject_kind` opt (e.g. a generic dataset inspection) all cases apply.
  defp applies?(_case, nil), do: true

  defp applies?(c, kind) do
    subjects = Map.get(c, "subjects", ["deterministic", "live"])
    to_string(kind) in subjects
  end

  defp to_case(c) do
    fixture_payload = %{
      "fixture" => c["fixture"],
      "query_embedding" => c["query_embedding"],
      "claim_query_embedding" => c["claim_query_embedding"]
    }

    %{
      id: c["id"],
      question: c["query"],
      gold: primary_name(c["expected"]),
      ingest_items: [%{role: :fixture, text: Jason.encode!(fixture_payload)}],
      meta: %{
        expected: c["expected"],
        category: c["category"],
        k: c["k"] || 5,
        supported: c["supported"] == true,
        target: c["target"] || "entities"
      }
    }
  end

  defp primary_name([%{"name" => name} | _]), do: name
  defp primary_name(_), do: ""
end
