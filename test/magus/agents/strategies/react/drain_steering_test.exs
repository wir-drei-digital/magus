defmodule Magus.Agents.Strategies.ReactStrategy.Runner.DrainSteeringTest do
  use ExUnit.Case, async: true

  alias Jido.AI.Reasoning.ReAct.State
  alias Jido.AI.Thread
  alias Magus.Agents.Strategies.ReactStrategy.Runner

  test "apply_steer_texts appends each non-blank text as a user message, in order" do
    state = State.new("hi", "sys", request_id: "r", run_id: "r")
    state = Runner.apply_steer_texts(state, ["first", "", "second"])

    roles_and_texts =
      state.thread
      |> Thread.to_messages()
      |> Enum.filter(&(Map.get(&1, :role) == :user))
      |> Enum.map(&Map.get(&1, :content))

    assert "first" in roles_and_texts
    assert "second" in roles_and_texts
    refute "" in roles_and_texts
  end
end
