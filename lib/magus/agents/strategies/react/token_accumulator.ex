defmodule Magus.Agents.Strategies.React.TokenAccumulator do
  @moduledoc """
  Pure helper for tracking cumulative token usage during a ReAct
  run and signaling when the per-run cap has been exceeded.

  The accumulator is a simple map with two keys:

    * `:accumulated_tokens` — running sum of `prompt_tokens + completion_tokens`
      observed across all LLM calls in the run.
    * `:max_tokens_per_run` — the hard cap (typically sourced from
      `CustomAgent.max_tokens_per_run`). `nil` or `0` are both treated
      as "unlimited".

  After each LLM response, the runner calls `observe/2` with the response's
  usage map. The helper returns `{:continue, state}` to keep iterating or
  `{:stop_budget_exceeded, state}` once the cap is met or exceeded, at
  which point the runner should halt the loop and mark the AgentRun as
  `:budget_exceeded`.
  """

  @type state :: %{
          accumulated_tokens: non_neg_integer(),
          max_tokens_per_run: non_neg_integer() | nil
        }

  @type usage :: %{
          optional(:prompt_tokens) => non_neg_integer() | nil,
          optional(:completion_tokens) => non_neg_integer() | nil
        }

  @doc """
  Adds the prompt + completion tokens from `usage` to the accumulator
  and decides whether the run should continue.

  Missing or nil usage keys default to 0. A `nil` or `0` cap is treated
  as unlimited.
  """
  @spec observe(state, usage) :: {:continue | :stop_budget_exceeded, state}
  def observe(%{accumulated_tokens: acc, max_tokens_per_run: cap} = state, usage) do
    delta = token_delta(usage)
    new_acc = acc + delta
    new_state = %{state | accumulated_tokens: new_acc}

    cond do
      is_nil(cap) or cap == 0 -> {:continue, new_state}
      new_acc >= cap -> {:stop_budget_exceeded, new_state}
      true -> {:continue, new_state}
    end
  end

  defp token_delta(usage) when is_map(usage) do
    prompt = Map.get(usage, :prompt_tokens) || Map.get(usage, "prompt_tokens") || 0
    completion = Map.get(usage, :completion_tokens) || Map.get(usage, "completion_tokens") || 0
    (prompt || 0) + (completion || 0)
  end

  defp token_delta(_), do: 0
end
