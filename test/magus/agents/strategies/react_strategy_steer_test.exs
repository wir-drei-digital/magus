defmodule Magus.Agents.Strategies.ReactStrategySteerTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Strategies.ReactStrategy

  test "decide_steer returns :inject when a worker run is active" do
    state = %{
      active_request_id: "req-1",
      react_worker_pid: self(),
      status: :awaiting_tool
    }

    assert ReactStrategy.decide_steer(state, %{texts: ["x"]}) == {:inject, "req-1", ["x"]}
  end

  test "decide_steer returns :redispatch when idle" do
    state = %{active_request_id: nil, react_worker_pid: nil, status: :idle}

    assert ReactStrategy.decide_steer(state, %{
             texts: ["x"],
             newest_id: "m-1",
             conversation_id: "c-1"
           }) == {:redispatch, "c-1", "m-1"}
  end
end
