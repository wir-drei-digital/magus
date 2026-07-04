defmodule Magus.SuperBrainRetrievalEvalE2ETest do
  use Magus.LiveE2ECase, async: false

  @moduletag timeout: 600_000

  alias Magus.Eval.Benchmarks.SuperBrainRetrieval
  alias Magus.Eval.Runner
  alias Magus.Eval.Subject.SuperBrainLive

  test "live retrieval eval runs the real builder + embedder", %{user: user} do
    dir = Path.join(System.tmp_dir!(), "sbr_e2e_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, run} =
      Runner.run(SuperBrainRetrieval,
        subject: SuperBrainLive,
        subject_kind: :live,
        ctx: %{user: user},
        results_dir: dir,
        recorded_at: DateTime.utc_now() |> DateTime.to_iso8601()
      )

    assert is_number(run.aggregate)
    assert run.scoreboard_path && File.exists?(run.scoreboard_path)

    claim_case = Enum.find(run.per_case, &(&1.category == "claim_recall"))

    assert claim_case,
           "expected a claim_recall case in the live run (cases.json subjects must include \"live\")"

    assert claim_case.recall_at_k == 1.0,
           "claim_recall graded at #{claim_case.recall_at_k}, expected 1.0 with real embeddings"

    assert run.aggregate == 1.0
  end
end
