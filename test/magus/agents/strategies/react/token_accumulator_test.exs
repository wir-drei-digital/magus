defmodule Magus.Agents.Strategies.React.TokenAccumulatorTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Strategies.React.TokenAccumulator

  test "stops when accumulated tokens exceed cap" do
    state = %{accumulated_tokens: 0, max_tokens_per_run: 100}

    {action, new_state} =
      TokenAccumulator.observe(state, %{prompt_tokens: 60, completion_tokens: 50})

    assert action == :stop_budget_exceeded
    assert new_state.accumulated_tokens == 110
  end

  test "continues while under cap" do
    state = %{accumulated_tokens: 0, max_tokens_per_run: 1000}

    {action, new_state} =
      TokenAccumulator.observe(state, %{prompt_tokens: 100, completion_tokens: 50})

    assert action == :continue
    assert new_state.accumulated_tokens == 150
  end

  test "nil cap is treated as unlimited" do
    state = %{accumulated_tokens: 1_000_000, max_tokens_per_run: nil}
    {action, _} = TokenAccumulator.observe(state, %{prompt_tokens: 1, completion_tokens: 1})
    assert action == :continue
  end

  test "0 cap is treated as unlimited" do
    state = %{accumulated_tokens: 1_000_000, max_tokens_per_run: 0}
    {action, _} = TokenAccumulator.observe(state, %{prompt_tokens: 1, completion_tokens: 1})
    assert action == :continue
  end

  test "exactly at cap stops" do
    state = %{accumulated_tokens: 0, max_tokens_per_run: 100}
    {action, _} = TokenAccumulator.observe(state, %{prompt_tokens: 50, completion_tokens: 50})
    assert action == :stop_budget_exceeded
  end

  test "missing usage keys default to 0" do
    state = %{accumulated_tokens: 100, max_tokens_per_run: 1000}
    {action, new_state} = TokenAccumulator.observe(state, %{})
    assert action == :continue
    assert new_state.accumulated_tokens == 100
  end
end
