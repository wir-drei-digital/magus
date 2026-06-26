defmodule Magus.Agents.Plugins.InboundSteerTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Plugins.InboundPlugin

  test "build_steer_outcome emits ai.react.steer when active" do
    msgs = [%{id: "m1", text: "a"}, %{id: "m2", text: "b"}]

    {:emit, signal} =
      InboundPlugin.build_steer_outcome(msgs, _active_request_id = "req-1", "conv-1")

    assert signal.type == "ai.react.steer"
    assert signal.data.texts == ["a", "b"]
    assert signal.data.newest_id == "m2"
    assert signal.data.conversation_id == "conv-1"
  end

  test "build_steer_outcome redispatches when idle" do
    msgs = [%{id: "m1", text: "a"}, %{id: "m2", text: "b"}]
    assert InboundPlugin.build_steer_outcome(msgs, nil, "conv-1") == {:redispatch, "conv-1", "m2"}
  end

  test "build_steer_outcome no-ops on empty queue" do
    assert InboundPlugin.build_steer_outcome([], "req-1", "conv-1") == :noop
  end
end
