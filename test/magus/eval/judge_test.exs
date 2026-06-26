defmodule Magus.Eval.JudgeTest do
  use ExUnit.Case, async: true

  alias Magus.Eval.Judge

  test "build_prompt includes the gold answer (reference-guided) and is pinned/versioned" do
    p = Judge.build_prompt(%{question: "Where?", answer: "Lisbon", gold: "Lisbon"})
    assert p =~ "Lisbon"
    assert p =~ "CORRECT" or p =~ "correct"
    assert p =~ Application.get_env(:magus, :eval_judge_prompt_version, "v1")
  end

  test "parse_verdict reads a yes verdict" do
    assert %{correct?: true, score: 1.0} =
             Judge.parse_verdict("VERDICT: CORRECT\nbecause it matches")
  end

  test "parse_verdict reads a no verdict" do
    assert %{correct?: false, score: +0.0} = Judge.parse_verdict("VERDICT: INCORRECT\nwrong city")
  end

  test "judge_model/1 precedence: :judge (the --judge flag) > :model > config" do
    assert Judge.judge_model(judge: "openrouter:a", model: "openrouter:b") == "openrouter:a"
    assert Judge.judge_model(model: "openrouter:b") == "openrouter:b"
    assert Judge.judge_model([]) == Application.get_env(:magus, :eval_judge_model)
  end
end
