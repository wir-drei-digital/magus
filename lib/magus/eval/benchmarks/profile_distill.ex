defmodule Magus.Eval.Benchmarks.ProfileDistill do
  @moduledoc """
  Profile distillation quality benchmark. Each case seeds user-scope
  memories (including contradictions, completed work, and one-off noise),
  runs the distiller, and grades the resulting document: are the gold facts
  stated, are the forbidden (stale/noise) facts absent, and is the document
  within the 800-token cap.
  """
  @behaviour Magus.Eval.Benchmark

  alias Magus.Agents.Clients.LLM, as: LLMClient

  @impl true
  def name, do: "profile_distill"

  @impl true
  def load_dataset(opts) do
    path =
      opts[:dataset_path] ||
        Path.join(:code.priv_dir(:magus), "eval/profile_distill/cases.json")

    with {:ok, body} <- File.read(path) do
      Jason.decode(body)
    end
  end

  @impl true
  def cases(dataset, _opts) do
    Enum.map(dataset, fn c ->
      %{
        id: c["id"],
        question: "distill",
        gold: %{
          "gold_facts" => c["gold_facts"] || [],
          "forbidden_facts" => c["forbidden_facts"] || []
        },
        meta: %{},
        ingest_items:
          Enum.map(c["seed_memories"], fn m -> %{role: :user, text: Jason.encode!(m)} end)
      }
    end)
  end

  @impl true
  def emit_hypotheses(results, path) do
    body =
      Enum.map_join(results, "\n", fn r ->
        Jason.encode!(%{id: r.id, document: r.answer || ""})
      end)

    File.write!(path, body <> "\n")
    :ok
  end

  @impl true
  def score(results, opts) do
    judge_model = opts[:judge] || Magus.Agents.Config.extraction_model()

    per_case =
      Enum.map(results, fn r ->
        gold = r.gold["gold_facts"]
        forbidden = r.gold["forbidden_facts"]
        verdict = judge_case(judge_model, r.answer || "", gold, forbidden)
        cap_ok = (get_in(r, [:meta, :token_estimate]) || 0) <= 800

        %{
          id: r.id,
          score: case_score(verdict.covered, verdict.forbidden_present, cap_ok),
          cap_ok: cap_ok,
          covered: verdict.covered,
          forbidden_present: verdict.forbidden_present
        }
      end)

    aggregate =
      case per_case do
        [] -> 0.0
        list -> Enum.sum(Enum.map(list, & &1.score)) / length(list)
      end

    %{aggregate: aggregate, per_case: per_case}
  end

  @doc """
  Deterministic case score: fraction of checks passed, where checks are
  each gold fact covered plus each forbidden fact absent. Halved when the
  document exceeds the token cap. Empty check set scores 0.0 (misconfigured
  case, should never happen with the shipped dataset).
  """
  def case_score(covered, forbidden_present, cap_ok) do
    checks = length(covered) + length(forbidden_present)

    if checks == 0 do
      0.0
    else
      passed = Enum.count(covered, & &1) + Enum.count(forbidden_present, &(not &1))
      raw = passed / checks
      if cap_ok, do: raw, else: raw * 0.5
    end
  end

  @judge_schema %{
    "type" => "object",
    "properties" => %{
      "covered" => %{"type" => "array", "items" => %{"type" => "boolean"}},
      "forbidden_present" => %{"type" => "array", "items" => %{"type" => "boolean"}}
    },
    "required" => ["covered", "forbidden_present"]
  }

  defp judge_case(_model, _document, [], []), do: %{covered: [], forbidden_present: []}

  defp judge_case(model, document, gold, forbidden) do
    prompt = """
    Profile document:
    <document>
    #{document}
    </document>

    Expected facts (is each one stated in the document, possibly reworded?):
    #{numbered(gold)}

    Forbidden facts (is each one present in the document?):
    #{numbered(forbidden)}

    Return "covered" as an array of exactly #{length(gold)} booleans and
    "forbidden_present" as an array of exactly #{length(forbidden)} booleans,
    both in the order listed above.
    """

    case LLMClient.llm_client().generate_object(model, prompt, @judge_schema,
           system_prompt: "You are a strict grader. Judge only from the document text."
         ) do
      {:ok, %{object: obj}} ->
        %{
          covered: pad_bools(obj["covered"], length(gold), false),
          forbidden_present: pad_bools(obj["forbidden_present"], length(forbidden), true)
        }

      {:error, _} ->
        # Judge failure grades worst-case so it cannot inflate the score.
        %{
          covered: List.duplicate(false, length(gold)),
          forbidden_present: List.duplicate(true, length(forbidden))
        }
    end
  end

  defp numbered([]), do: "(none)"

  defp numbered(items) do
    items |> Enum.with_index(1) |> Enum.map_join("\n", fn {item, i} -> "#{i}. #{item}" end)
  end

  defp pad_bools(list, expected, fill) when is_list(list) do
    list
    |> Enum.map(&(&1 == true))
    |> Enum.take(expected)
    |> then(fn l -> l ++ List.duplicate(fill, expected - length(l)) end)
  end

  defp pad_bools(_other, expected, fill), do: List.duplicate(fill, expected)
end
