defmodule Magus.EvalBenchmarksE2ETest do
  use Magus.LiveE2ECase, async: false

  alias Magus.Eval.{Runner, Subject}
  alias Magus.Eval.Benchmarks.{GAIA, LongMemEval}

  @moduletag timeout: 600_000

  test "LongMemEval runs end to end when a dataset is present", %{user: user, model: model} do
    fixture = Path.join([File.cwd!(), "test/support/fixtures/eval/longmemeval_sample.json"])
    dir = Path.join(System.tmp_dir!(), "eval_lme_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    ctx = %{
      user: user,
      model: model,
      workspace: Magus.Generators.generate(Magus.Generators.workspace(actor: user))
    }

    {:ok, run} =
      Runner.run(LongMemEval,
        ctx: ctx,
        subject: Subject.Live,
        path: fixture,
        limit: 1,
        results_dir: dir,
        recorded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        hypotheses_path: Path.join(dir, "hyp.jsonl")
      )

    assert is_number(run.aggregate)
    assert is_map(run.per_ability)
    # limit 1 runs only q1 (question_type "single-session-user"). If the Runner
    # dropped the case meta, per_ability would collapse to a single "unknown".
    assert "single-session-user" in Map.keys(run.per_ability)
    refute Map.has_key?(run.per_ability, "unknown")
    assert run.scoreboard_path && File.exists?(run.scoreboard_path)
  end

  test "GAIA runs end to end on a simple text task", %{user: user, model: model} do
    fixture = Path.join([File.cwd!(), "test/support/fixtures/eval/gaia_sample.json"])
    dir = Path.join(System.tmp_dir!(), "eval_gaia_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    ctx = %{
      user: user,
      model: model,
      workspace: Magus.Generators.generate(Magus.Generators.workspace(actor: user))
    }

    {:ok, run} =
      Runner.run(GAIA,
        ctx: ctx,
        subject: Subject.Live,
        path: fixture,
        limit: 1,
        results_dir: dir,
        recorded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        hypotheses_path: Path.join(dir, "hyp.jsonl")
      )

    assert is_number(run.aggregate)
    assert is_map(run.per_level)
    # limit 1 runs only t1 (Level 1). If the Runner dropped the case meta,
    # per_level would collapse to a single nil bucket.
    assert Map.has_key?(run.per_level, 1)
    refute Map.has_key?(run.per_level, nil)
    assert run.scoreboard_path && File.exists?(run.scoreboard_path)
  end
end
