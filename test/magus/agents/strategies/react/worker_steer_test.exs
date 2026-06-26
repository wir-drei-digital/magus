defmodule Magus.Agents.Strategies.ReactStrategy.Worker.SteerTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Strategies.ReactStrategy.Worker.Strategy

  test "steer_run sends {:react_stream_steer, _} to the active runtime task" do
    test_pid = self()
    fake_task = spawn(fn -> receive do: (msg -> send(test_pid, {:got, msg})) end)

    state = %{
      status: :running,
      active_request_id: "req-1",
      runtime_task: fake_task
    }

    Strategy.send_steer(state, "req-1", ["hello"])

    assert_receive {:got, {:react_stream_steer, %{texts: ["hello"]}}}, 500
  end

  test "send_steer ignores a non-matching request id" do
    state = %{status: :running, active_request_id: "req-1", runtime_task: self()}
    assert Strategy.send_steer(state, "other", ["x"]) == :ignored
    refute_receive {:react_stream_steer, _}, 100
  end
end
