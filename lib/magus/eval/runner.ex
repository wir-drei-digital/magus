defmodule Magus.Eval.Runner do
  @moduledoc "Orchestrates one benchmark run: load, ingest, query, score, record."

  require Logger

  alias Magus.Eval.Scoreboard

  def run(benchmark_mod, opts \\ []) do
    subject = Keyword.get(opts, :subject, Magus.Eval.Subject.Live)
    ctx = Keyword.get(opts, :ctx, %{})

    with {:ok, dataset} <- benchmark_mod.load_dataset(opts) do
      cases =
        benchmark_mod.cases(dataset, opts)
        |> maybe_limit(opts[:limit])

      results = Enum.map(cases, &run_case(&1, subject, ctx))
      scored = benchmark_mod.score(results, opts)

      if path = opts[:hypotheses_path] do
        File.mkdir_p!(Path.dirname(path))
        benchmark_mod.emit_hypotheses(results, path)
      end

      scoreboard_path =
        if opts[:dry_run] do
          nil
        else
          {:ok, p} =
            Scoreboard.record(
              %{
                benchmark: benchmark_mod.name(),
                aggregate: scored.aggregate,
                config: %{limit: opts[:limit], subject: inspect(subject)},
                cases: scored.per_case,
                recorded_at: Keyword.fetch!(opts, :recorded_at)
              },
              dir: opts[:results_dir]
            )

          p
        end

      {:ok, Map.put(scored, :scoreboard_path, scoreboard_path)}
    end
  end

  defp run_case(c, subject, ctx) do
    with {:ok, ctx} <- subject.reset(ctx),
         {:ok, ctx} <- subject.ingest(ctx, c.ingest_items),
         {:ok, %{answer: answer, meta: meta}} <- subject.query(ctx, c.question) do
      %{
        id: c.id,
        question: c.question,
        gold: c.gold,
        answer: answer,
        meta: Map.merge(c.meta || %{}, meta)
      }
    else
      {:error, reason} ->
        Logger.error("eval case #{c.id} failed: #{inspect(reason)}")
        failed_case(c, reason)

      other ->
        Logger.error("eval case #{c.id} returned an unexpected value: #{inspect(other)}")
        failed_case(c, other)
    end
  end

  defp failed_case(c, reason) do
    %{
      id: c.id,
      question: c.question,
      gold: c.gold,
      answer: "",
      meta: Map.merge(c.meta || %{}, %{error: inspect(reason)})
    }
  end

  defp maybe_limit(cases, nil), do: cases
  defp maybe_limit(cases, n) when is_integer(n), do: Enum.take(cases, n)
end
