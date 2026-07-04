defmodule Magus.Eval.JudgeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Magus.Eval.Judge

  # Client stub that returns {:error} for the first `fail_until - 1` calls, then
  # a CORRECT verdict. Call count lives in the caller's process dictionary, which
  # is safe because grade/2 calls complete/3 synchronously in the same process.
  defmodule FlakyClient do
    def complete(_model, _prompt, _opts) do
      n = Process.get(:flaky_calls, 0) + 1
      Process.put(:flaky_calls, n)

      if n < Process.get(:flaky_until, 3) do
        {:error, :rate_limited}
      else
        {:ok, %{text: "VERDICT: CORRECT\nrecovered"}}
      end
    end
  end

  defmodule AlwaysFailClient do
    def complete(_model, _prompt, _opts) do
      Process.put(:fail_calls, Process.get(:fail_calls, 0) + 1)
      {:error, :provider_down}
    end
  end

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

  test "grade retries a transient judge error and then succeeds" do
    Process.put(:flaky_calls, 0)
    Process.put(:flaky_until, 3)

    assert {:ok, %{correct?: true}} =
             Judge.grade(%{question: "q", answer: "a", gold: "a"},
               client: FlakyClient,
               judge_retry_base_ms: 0
             )

    # Two failures then success = exactly 3 calls: the transient error did not
    # get scored as an incorrect answer.
    assert Process.get(:flaky_calls) == 3
  end

  test "grade retries up to the limit then returns {:error}" do
    Process.put(:fail_calls, 0)

    # capture_log swallows the "judge failed" warning so test output stays clean
    # regardless of the configured log level.
    capture_log(fn ->
      assert {:error, :provider_down} =
               Judge.grade(%{question: "q", answer: "a", gold: "a"},
                 client: AlwaysFailClient,
                 judge_max_attempts: 3,
                 judge_retry_base_ms: 0
               )
    end)

    # Exactly max_attempts calls: it retried, it did not give up after one error.
    assert Process.get(:fail_calls) == 3
  end
end
