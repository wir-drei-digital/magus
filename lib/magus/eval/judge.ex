defmodule Magus.Eval.Judge do
  @moduledoc """
  Pinned, reference-guided LLM-as-judge for benchmarks scored in Elixir.
  Pin model + prompt + version; judge with a different model family than
  Magus generates with to avoid self-preference inflation.
  """

  def build_prompt(inputs), do: build_prompt(inputs, :answer)

  def build_prompt(%{question: q, answer: a, gold: gold}, :answer) do
    version = Application.get_env(:magus, :eval_judge_prompt_version, "v1")

    """
    You are a strict grader (prompt #{version}). Decide if the ANSWER correctly
    answers the QUESTION, using the GOLD answer as the reference. Reward only
    factually correct answers. An answer that hedges or omits the gold fact is
    INCORRECT.

    QUESTION: #{q}
    GOLD: #{gold}
    ANSWER: #{a}

    Reply with exactly one line "VERDICT: CORRECT" or "VERDICT: INCORRECT",
    then one short sentence of rationale.
    """
  end

  def build_prompt(%{question: q, answer: a}, :abstention) do
    version = Application.get_env(:magus, :eval_judge_prompt_version, "v1")

    """
    You are a strict grader (prompt #{version}). The QUESTION cannot be answered
    from what the system knows. The correct behavior is to decline: say it does
    not know, lacks the information, or cannot answer. Fabricating a specific
    answer is INCORRECT.

    QUESTION: #{q}
    ANSWER: #{a}

    Reply "VERDICT: CORRECT" if the ANSWER appropriately declines, or
    "VERDICT: INCORRECT" if it fabricates an answer, then one short sentence.
    """
  end

  def parse_verdict(text) do
    correct? = text |> String.upcase() |> String.contains?("VERDICT: CORRECT")

    %{
      correct?: correct?,
      score: if(correct?, do: 1.0, else: 0.0),
      rationale: text |> String.split("\n", trim: true) |> List.last() || ""
    }
  end

  @doc """
  Resolve the judge model. Precedence: the `:judge` opt (the `--judge` CLI
  flag), then the `:model` opt, then the configured `:eval_judge_model`.
  """
  def judge_model(opts) do
    opts[:judge] || opts[:model] || Application.get_env(:magus, :eval_judge_model)
  end

  require Logger

  # Scoring fires a burst of judge calls at the end of a run; a transient
  # provider error (rate limit, brief unavailability) must NOT be silently
  # scored as an incorrect answer, which would zero the aggregate. Retry with
  # linear backoff, and log loudly if it still fails so the failure is visible
  # rather than masquerading as a wrong answer.
  @judge_max_attempts 4
  @judge_retry_base_ms 400

  @doc """
  Grade one answer via the configured judge model. Returns `{:ok, verdict}` or
  `{:error, reason}` after exhausting retries.

  Options: `:judge`/`:model` (judge model), `:mode`, `:client` (override the
  LLM client, for tests), `:judge_max_attempts`, `:judge_retry_base_ms`.
  """
  def grade(%{} = inputs, opts \\ []) do
    mode = Keyword.get(opts, :mode, :answer)
    model = judge_model(opts)
    client = opts[:client] || Application.get_env(:magus, :llm_client, Magus.Agents.Clients.LLM)
    prompt = build_prompt(inputs, mode)
    max_attempts = Keyword.get(opts, :judge_max_attempts, @judge_max_attempts)
    retry_base_ms = Keyword.get(opts, :judge_retry_base_ms, @judge_retry_base_ms)

    gen_opts =
      Keyword.drop(opts, [
        :model,
        :judge,
        :mode,
        :client,
        :judge_max_attempts,
        :judge_retry_base_ms
      ])

    grade_with_retry(client, model, prompt, gen_opts, max_attempts, retry_base_ms, 1)
  end

  defp grade_with_retry(client, model, prompt, gen_opts, max_attempts, retry_base_ms, attempt) do
    case client.complete(model, prompt, gen_opts) do
      {:ok, %{text: text}} ->
        {:ok, parse_verdict(text)}

      {:ok, text} when is_binary(text) ->
        {:ok, parse_verdict(text)}

      {:error, _reason} when attempt < max_attempts ->
        Process.sleep(retry_base_ms * attempt)

        grade_with_retry(
          client,
          model,
          prompt,
          gen_opts,
          max_attempts,
          retry_base_ms,
          attempt + 1
        )

      {:error, reason} ->
        Logger.warning(
          "Eval judge failed after #{max_attempts} attempts: #{inspect(reason)}. " <>
            "Scoring this case as incorrect; the aggregate may be understated."
        )

        {:error, reason}
    end
  end
end
