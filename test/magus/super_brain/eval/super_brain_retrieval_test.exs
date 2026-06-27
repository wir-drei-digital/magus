defmodule Magus.SuperBrain.Eval.SuperBrainRetrievalTest do
  @moduledoc "Deterministic regression guard: supported cases must hold at recall 1.0; xfail gaps must still fail."
  use Magus.ResourceCase, async: false

  alias Magus.Eval.Benchmarks.SuperBrainRetrieval
  alias Magus.Eval.Runner
  alias Magus.Eval.Subject.SuperBrainDeterministic

  test "supported cases pass and known gaps still fail" do
    user = generate(user())

    {:ok, run} =
      Runner.run(SuperBrainRetrieval,
        subject: SuperBrainDeterministic,
        subject_kind: :deterministic,
        ctx: %{user: user},
        dry_run: true,
        recorded_at: "test"
      )

    assert run.aggregate == 1.0

    for c <- run.per_case, c.supported == false do
      refute c.correct?, "known-gap case #{c.id} unexpectedly passed; promote it to supported"
    end
  end
end
