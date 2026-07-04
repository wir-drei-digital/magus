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

  @doc "Grade one answer via the configured judge model. Returns {:ok, verdict}."
  def grade(%{} = inputs, opts \\ []) do
    mode = Keyword.get(opts, :mode, :answer)
    model = judge_model(opts)
    client = Application.get_env(:magus, :llm_client, Magus.Agents.Clients.LLM)
    prompt = build_prompt(inputs, mode)
    gen_opts = Keyword.drop(opts, [:model, :judge, :mode])

    case client.complete(model, prompt, gen_opts) do
      {:ok, %{text: text}} -> {:ok, parse_verdict(text)}
      {:ok, text} when is_binary(text) -> {:ok, parse_verdict(text)}
      {:error, reason} -> {:error, reason}
    end
  end
end
