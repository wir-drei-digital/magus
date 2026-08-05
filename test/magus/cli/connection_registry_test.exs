defmodule Magus.Cli.ConnectionRegistryTest do
  use ExUnit.Case, async: true

  alias Magus.Cli.ConnectionRegistry

  # Spawns a process that registers under `user_id` and stays alive until told
  # to stop. Returns its pid once registration is confirmed.
  defp spawn_registered(user_id) do
    test = self()

    pid =
      spawn(fn ->
        :ok = ConnectionRegistry.register(user_id)
        send(test, {:registered, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:registered, ^pid}, 1_000
    pid
  end

  test "registers the calling process under a user id and looks it up" do
    uid = "user-#{System.unique_integer([:positive])}"
    assert :ok = ConnectionRegistry.register(uid)
    assert ConnectionRegistry.lookup(uid) == self()
  end

  test "unknown user id resolves to nil (fail-closed)" do
    assert ConnectionRegistry.lookup("nope-#{System.unique_integer([:positive])}") == nil
  end

  test "non-binary user id resolves to nil (fail-closed)" do
    assert ConnectionRegistry.lookup(nil) == nil
  end

  test "the most recently registered live connection wins" do
    uid = "user-#{System.unique_integer([:positive])}"
    old = spawn_registered(uid)

    # Self registers later, so it must win the lookup over the older process.
    assert :ok = ConnectionRegistry.register(uid)
    assert ConnectionRegistry.lookup(uid) == self()

    send(old, :stop)
  end

  test "a dead newest connection is skipped in favor of an older live one" do
    uid = "user-#{System.unique_integer([:positive])}"
    assert :ok = ConnectionRegistry.register(uid)

    newest = spawn_registered(uid)
    ref = Process.monitor(newest)
    Process.exit(newest, :kill)
    assert_receive {:DOWN, ^ref, :process, ^newest, :killed}, 1_000

    assert ConnectionRegistry.lookup(uid) == self()
  end
end
