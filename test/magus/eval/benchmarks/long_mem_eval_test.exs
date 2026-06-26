defmodule Magus.Eval.Benchmarks.LongMemEvalTest do
  use ExUnit.Case, async: true

  alias Magus.Eval.Benchmarks.LongMemEval

  defp fixture do
    Path.join([File.cwd!(), "test/support/fixtures/eval/longmemeval_sample.json"])
    |> File.read!()
    |> Jason.decode!()
  end

  test "name/0" do
    assert LongMemEval.name() == "longmemeval"
  end

  test "cases/2 flattens haystack sessions chronologically into ingest_items" do
    [c1, c2] = LongMemEval.cases(fixture(), [])

    assert c1.id == "q1"
    assert c1.question == "What city did I move to?"
    assert c1.gold == "Lisbon"
    assert c1.meta == %{question_type: "single-session-user", abstention: false}
    # sessions sorted by date ascending: 2026-01-01 session first, then 2026-01-02
    assert [
             %{role: :user, text: "Hello there."},
             %{role: :assistant, text: "Hi!"},
             %{role: :user, text: "Reminder, I now live in Lisbon."},
             %{role: :assistant, text: "Noted, Lisbon."}
           ] =
             c1.ingest_items

    assert c2.id == "q2_abs"
    assert c2.meta.abstention == true
  end

  test "tally/1 computes overall and per-ability accuracy" do
    graded = [
      %{question_type: "single-session-user", abstention: false, correct?: true},
      %{question_type: "single-session-user", abstention: false, correct?: false},
      %{question_type: "knowledge-update", abstention: true, correct?: true}
    ]

    t = LongMemEval.tally(graded)
    assert t.total == 3
    assert t.aggregate == 2 / 3
    assert t.per_ability["single-session-user"] == %{total: 2, correct: 1, accuracy: 0.5}
    assert t.per_ability["knowledge-update"] == %{total: 1, correct: 1, accuracy: 1.0}
  end
end
