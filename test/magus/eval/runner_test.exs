defmodule Magus.Eval.RunnerTest do
  use ExUnit.Case, async: true

  alias Magus.Eval.Runner

  defmodule FakeSubject do
    @behaviour Magus.Eval.Subject
    @impl true
    def reset(ctx), do: {:ok, ctx}
    @impl true
    def ingest(ctx, _items), do: {:ok, ctx}
    @impl true
    # Echo the gold for the "home-city" case, wrong answer otherwise, so the
    # aggregate is deterministic regardless of LLM.
    def query(_ctx, question) do
      answer = if String.contains?(question, "city"), do: "You live in Lisbon.", else: "no idea"
      {:ok, %{answer: answer, meta: %{fake: true}}}
    end
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "eval_runner_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "run/2 ingests, queries, scores, and records to the scoreboard", %{dir: dir} do
    assert {:ok, run} =
             Runner.run(Magus.Eval.Benchmarks.CoverageSmoke,
               subject: FakeSubject,
               ctx: %{},
               results_dir: dir,
               recorded_at: "2026-06-25T00:00:00Z",
               hypotheses_path: Path.join(dir, "hyp.jsonl")
             )

    # only the "city" case is answered correctly by the fake
    assert run.aggregate > 0.0 and run.aggregate < 1.0
    assert run.scoreboard_path == Path.join(dir, "coverage_smoke.jsonl")
    assert File.exists?(run.scoreboard_path)
  end

  test "run/2 with dry_run does not write the scoreboard", %{dir: dir} do
    assert {:ok, run} =
             Runner.run(Magus.Eval.Benchmarks.CoverageSmoke,
               subject: FakeSubject,
               ctx: %{},
               dry_run: true,
               results_dir: dir,
               recorded_at: "t",
               hypotheses_path: Path.join(dir, "hyp.jsonl")
             )

    assert run.scoreboard_path == nil
    refute File.exists?(Path.join(dir, "coverage_smoke.jsonl"))
  end

  test "run/2 honors :limit", %{dir: dir} do
    {:ok, run} =
      Runner.run(Magus.Eval.Benchmarks.CoverageSmoke,
        subject: FakeSubject,
        ctx: %{},
        limit: 1,
        results_dir: dir,
        recorded_at: "t",
        hypotheses_path: Path.join(dir, "hyp.jsonl")
      )

    assert length(run.per_case) == 1
  end

  # A subject whose query/2 always returns empty meta, exactly like Subject.Live.
  # If the Runner did not merge the case meta into the result, the benchmark's
  # score/2 would never see the case's level/question_type. This is the guard
  # that catches the "result meta clobbers case meta" regression.
  defmodule EmptyMetaSubject do
    @behaviour Magus.Eval.Subject
    @impl true
    def reset(ctx), do: {:ok, ctx}
    @impl true
    def ingest(ctx, _items), do: {:ok, ctx}
    @impl true
    def query(_ctx, _question), do: {:ok, %{answer: "", meta: %{}}}
  end

  test "run/2 carries case meta into score/2 so per-level keys survive" do
    fixture = Path.join([File.cwd!(), "test/support/fixtures/eval/gaia_sample.json"])

    {:ok, run} =
      Runner.run(Magus.Eval.Benchmarks.GAIA,
        subject: EmptyMetaSubject,
        ctx: %{},
        path: fixture,
        limit: 1,
        dry_run: true
      )

    # GAIA score/2 is deterministic (no judge). The first text task is Level 1.
    # Post-fix the case's level survives; pre-fix it collapsed to a nil bucket.
    assert Map.has_key?(run.per_level, 1)
    refute Map.has_key?(run.per_level, nil)
  end

  # A subject whose query/2 returns a shape the Runner does not expect (neither
  # {:ok, %{answer, meta}} nor {:error, _}). Without a catch-all the run_case
  # `with/else` raises WithClauseError and aborts the whole run.
  defmodule MalformedSubject do
    @behaviour Magus.Eval.Subject
    @impl true
    def reset(ctx), do: {:ok, ctx}
    @impl true
    def ingest(ctx, _items), do: {:ok, ctx}
    @impl true
    def query(_ctx, _question), do: {:ok, %{unexpected: true}}
  end

  test "run/2 records a failed case (does not crash) on a malformed Subject return" do
    fixture = Path.join([File.cwd!(), "test/support/fixtures/eval/gaia_sample.json"])

    assert {:ok, run} =
             Runner.run(Magus.Eval.Benchmarks.GAIA,
               subject: MalformedSubject,
               ctx: %{},
               path: fixture,
               limit: 1,
               dry_run: true
             )

    # The case is recorded as incorrect (empty answer cannot match the gold),
    # and the case meta (level) still survives so per_level buckets correctly.
    assert run.aggregate == +0.0
    assert [%{correct?: false}] = run.per_case
    assert Map.has_key?(run.per_level, 1)
  end
end
