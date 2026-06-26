defmodule Magus.Eval.Subject.LiveTest do
  use ExUnit.Case, async: true

  alias Magus.Eval.Subject.Live

  # wait_for_complete/1 must bound the total wait by a monotonic deadline, not
  # reset its budget on every ignored agent_signal broadcast. With a steady
  # stream of ignored broadcasts arriving more often than the timeout, the old
  # implementation would wait until `timeout` after the LAST broadcast (here
  # roughly 2s); the deadline implementation returns :timeout within roughly
  # `timeout` of the start.
  test "wait_for_complete honors a monotonic deadline despite a stream of ignored broadcasts" do
    parent = self()

    ignored = %Phoenix.Socket.Broadcast{
      topic: "agents:test",
      event: "agent_signal",
      payload: %{type: "thinking.chunk"}
    }

    sender =
      spawn(fn ->
        Enum.each(1..40, fn _ ->
          send(parent, ignored)
          Process.sleep(50)
        end)
      end)

    {elapsed_us, result} = :timer.tc(fn -> Live.wait_for_complete(150) end)
    Process.exit(sender, :kill)

    assert result == :timeout
    # New (deadline) path returns near 150ms; old (resetting) path would be
    # ~2000ms. A 1200ms ceiling separates them with wide margin in both directions.
    assert div(elapsed_us, 1000) < 1200
  end

  test "wait_for_complete returns :ok when response.complete arrives" do
    send(self(), %Phoenix.Socket.Broadcast{
      topic: "agents:test",
      event: "agent_signal",
      payload: %{type: "response.complete"}
    })

    assert Live.wait_for_complete(1_000) == :ok
  end
end
