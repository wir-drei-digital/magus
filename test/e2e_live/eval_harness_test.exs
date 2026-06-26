defmodule Magus.EvalHarnessE2ETest do
  use Magus.LiveE2ECase, async: false

  alias Magus.Eval.{Runner, Subject, Judge}
  alias Magus.Eval.Benchmarks.CoverageSmoke

  @moduletag timeout: 600_000

  test "CoverageSmoke runs end to end and records a scoreboard", %{user: user, model: model} do
    dir = Path.join(System.tmp_dir!(), "eval_e2e_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    # `use Magus.LiveE2ECase` already swapped the LLM client, started the
    # :conversations InstanceManager, and created the user/model/subscription.
    # Build ctx directly from those fixtures (calling Harness.setup again would
    # re-run create_live_model and crash on the model's unique key).
    ctx = %{
      user: user,
      model: model,
      workspace: Magus.Generators.generate(Magus.Generators.workspace(actor: user))
    }

    {:ok, run} =
      Runner.run(CoverageSmoke,
        ctx: ctx,
        subject: Subject.Live,
        limit: 1,
        results_dir: dir,
        recorded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        hypotheses_path: Path.join(dir, "hyp.jsonl")
      )

    assert is_number(run.aggregate)
    assert run.scoreboard_path && File.exists?(run.scoreboard_path)

    assert [%{"benchmark" => "coverage_smoke"}] =
             Magus.Eval.Scoreboard.recent("coverage_smoke", 1, dir: dir)
  end

  test "Judge grades a correct answer as correct", %{model: model} do
    {:ok, verdict} =
      Judge.grade(%{question: "Which city?", answer: "Lisbon", gold: "Lisbon"}, model: model.key)

    assert verdict.correct? == true
  end
end
