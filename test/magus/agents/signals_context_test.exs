defmodule Magus.Agents.SignalsContextTest do
  use ExUnit.Case, async: true

  test "context_updated broadcasts the snapshot on the agents topic" do
    conv_id = Ecto.UUID.generate()
    topic = "agents:#{conv_id}"
    Phoenix.PubSub.subscribe(Magus.PubSub, topic)
    Magus.Agents.Signals.context_updated(conv_id, %{total_tokens: 10})

    assert_receive %Phoenix.Socket.Broadcast{
                     topic: ^topic,
                     event: "agent_signal",
                     payload: %{type: "context.updated", total_tokens: 10}
                   },
                   500
  end
end
