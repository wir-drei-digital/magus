defmodule Mix.Tasks.Magus.Eval do
  @shortdoc "Run an eval benchmark through the real agent pipeline"
  @moduledoc """
      MIX_ENV=test mix magus.eval <benchmark> [--limit N] [--dry-run] [--judge MODEL] [--out DIR]

  Benchmarks: coverage_smoke, longmemeval, gaia

  Requires `OPENROUTER_API_KEY` (and a judge key for judged benchmarks).
  Runs against the configured (eval) database, never dev or prod data.

  ## Why MIX_ENV=test

  This task lives in `test/support/` (compiled only under `MIX_ENV=test` via
  `elixirc_paths(:test)`) because it wires together `Magus.Eval.Harness` and
  `Magus.Eval.Subject.Live`, which depend on test-only modules
  (`Magus.Generators`, `Magus.LiveE2ECase`). Placing the task in `lib/` would
  pull those test-only modules into the `dev`/`prod` build and break the running
  dev server. Mix discovers tasks by module name (`Mix.Tasks.*`) from loaded
  code paths, so it is found and run as:

      MIX_ENV=test mix magus.eval coverage_smoke
  """
  use Mix.Task

  @benchmarks %{
    "coverage_smoke" => Magus.Eval.Benchmarks.CoverageSmoke,
    "longmemeval" => Magus.Eval.Benchmarks.LongMemEval,
    "gaia" => Magus.Eval.Benchmarks.GAIA,
    "super_brain_retrieval" => Magus.Eval.Benchmarks.SuperBrainRetrieval
  }

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} =
      OptionParser.parse(argv,
        strict: [
          limit: :integer,
          dry_run: :boolean,
          judge: :string,
          out: :string,
          subject: :string
        ]
      )

    benchmark =
      case args do
        [name] -> Map.get(@benchmarks, name)
        _ -> nil
      end

    unless benchmark do
      Mix.raise(
        "Usage: MIX_ENV=test mix magus.eval <#{Enum.join(Map.keys(@benchmarks), "|")}> " <>
          "[--limit N] [--dry-run] [--judge MODEL] [--out DIR]"
      )
    end

    Mix.Task.run("app.start")

    {:ok, ctx} = Magus.Eval.Harness.setup([])

    {subject_mod, subject_kind} =
      case opts[:subject] do
        "live" ->
          {Magus.Eval.Subject.Live, :live}

        "deterministic" ->
          {Magus.Eval.Subject.SuperBrainDeterministic, :deterministic}

        _ when benchmark == Magus.Eval.Benchmarks.SuperBrainRetrieval ->
          {Magus.Eval.Subject.SuperBrainDeterministic, :deterministic}

        _ ->
          {Magus.Eval.Subject.Live, nil}
      end

    run_opts =
      [
        ctx: ctx,
        subject: subject_mod,
        subject_kind: subject_kind,
        limit: opts[:limit],
        dry_run: opts[:dry_run] || false,
        judge: opts[:judge],
        results_dir: opts[:out],
        recorded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        hypotheses_path: Path.join(opts[:out] || "eval/results", "#{benchmark.name()}.hyp.jsonl")
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    try do
      {:ok, run} = Magus.Eval.Runner.run(benchmark, run_opts)
      Mix.shell().info("\n#{benchmark.name()} aggregate: #{Float.round(run.aggregate * 1.0, 4)}")
      if run.scoreboard_path, do: Mix.shell().info("scoreboard: #{run.scoreboard_path}")
    after
      Magus.Eval.Harness.teardown(ctx)
    end
  end
end
