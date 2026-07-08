defmodule Magus.Agents.Support.TurnKeepaliveTest do
  # async: false — global config for the tick interval.
  use ExUnit.Case, async: false

  alias Magus.Agents.Support.TurnKeepalive

  setup do
    original = Application.get_env(:magus, :agents, [])

    Application.put_env(
      :magus,
      :agents,
      Keyword.put(original, :turn_keepalive_interval_ms, 30)
    )

    on_exit(fn -> Application.put_env(:magus, :agents, original) end)

    conversation_id = Ecto.UUID.generate()
    MagusWeb.Endpoint.subscribe("agents:#{conversation_id}")
    %{conversation_id: conversation_id}
  end

  test "broadcasts turn.keepalive on the conversation topic", %{conversation_id: cid} do
    ticker = TurnKeepalive.start(cid)

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "agent_signal",
                     payload: %{type: "turn.keepalive"}
                   },
                   1_000

    TurnKeepalive.stop(ticker)
  end

  test "stop/1 ends the ticker", %{conversation_id: cid} do
    ticker = TurnKeepalive.start(cid)
    assert_receive %Phoenix.Socket.Broadcast{payload: %{type: "turn.keepalive"}}, 1_000

    TurnKeepalive.stop(ticker)
    Process.sleep(50)
    drain_keepalives()
    refute_receive %Phoenix.Socket.Broadcast{payload: %{type: "turn.keepalive"}}, 150
  end

  test "the ticker dies with the watched process", %{conversation_id: cid} do
    watched = spawn(fn -> Process.sleep(:infinity) end)
    ticker = TurnKeepalive.start(cid, watch: watched)
    assert_receive %Phoenix.Socket.Broadcast{payload: %{type: "turn.keepalive"}}, 1_000

    Process.exit(watched, :kill)
    Process.sleep(50)
    drain_keepalives()
    refute_receive %Phoenix.Socket.Broadcast{payload: %{type: "turn.keepalive"}}, 150

    refute is_pid(ticker) and Process.alive?(ticker)
  end

  test "start returns nil (and never ticks) without a conversation id" do
    assert TurnKeepalive.start(nil) == nil
    assert TurnKeepalive.stop(nil) == :ok
  end

  defp drain_keepalives do
    receive do
      %Phoenix.Socket.Broadcast{payload: %{type: "turn.keepalive"}} -> drain_keepalives()
    after
      0 -> :ok
    end
  end
end
