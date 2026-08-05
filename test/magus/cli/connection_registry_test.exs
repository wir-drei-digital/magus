defmodule Magus.Cli.ConnectionRegistryTest do
  use ExUnit.Case, async: true

  alias Magus.Cli.ConnectionRegistry

  # Spawns a process that registers under `user_id` for `conversation_id` and
  # stays alive until told to stop. Returns its pid once registration is
  # confirmed.
  defp spawn_registered(user_id, conversation_id) do
    test = self()

    pid =
      spawn(fn ->
        :ok = ConnectionRegistry.register(user_id, conversation_id)
        send(test, {:registered, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:registered, ^pid}, 1_000
    pid
  end

  defp uid, do: "user-#{System.unique_integer([:positive])}"

  test "registers the calling process under a user id and looks it up" do
    user_id = uid()
    assert :ok = ConnectionRegistry.register(user_id, "conv-1")
    assert ConnectionRegistry.lookup(user_id, "conv-1") == self()
  end

  test "unknown user id resolves to nil (fail-closed)" do
    assert ConnectionRegistry.lookup("nope-#{System.unique_integer([:positive])}", "c") == nil
  end

  test "non-binary user id resolves to nil (fail-closed)" do
    assert ConnectionRegistry.lookup(nil, "c") == nil
  end

  test "prefers the connection on the turn's conversation over a newer one" do
    user_id = uid()
    assert :ok = ConnectionRegistry.register(user_id, "conv-laptop")
    other = spawn_registered(user_id, "conv-remote")

    # The remote-box connection is newer, but a turn in conv-laptop must be
    # served by the laptop connection.
    assert ConnectionRegistry.lookup(user_id, "conv-laptop") == self()
    assert ConnectionRegistry.lookup(user_id, "conv-remote") == other

    send(other, :stop)
  end

  test "falls back to the most recently registered live connection when no conversation matches" do
    user_id = uid()
    old = spawn_registered(user_id, "conv-a")
    assert :ok = ConnectionRegistry.register(user_id, "conv-b")

    assert ConnectionRegistry.lookup(user_id, "conv-unknown") == self()
    assert ConnectionRegistry.lookup(user_id, nil) == self()

    send(old, :stop)
  end

  test "a dead newest connection is skipped in favor of an older live one" do
    user_id = uid()
    assert :ok = ConnectionRegistry.register(user_id, "conv-a")

    newest = spawn_registered(user_id, "conv-b")
    ref = Process.monitor(newest)
    Process.exit(newest, :kill)
    assert_receive {:DOWN, ^ref, :process, ^newest, :killed}, 1_000

    assert ConnectionRegistry.lookup(user_id, "conv-b") == self()
  end
end
