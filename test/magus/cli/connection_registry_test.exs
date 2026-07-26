defmodule Magus.Cli.ConnectionRegistryTest do
  use ExUnit.Case, async: true

  @registry Magus.Cli.ConnectionRegistry

  test "a process can register under a session id and be looked up" do
    sid = "sess-#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.register(@registry, sid, nil)
    assert [{pid, _}] = Registry.lookup(@registry, sid)
    assert pid == self()
  end

  test "unknown session id resolves to empty (fail-closed)" do
    assert Registry.lookup(@registry, "nope-#{System.unique_integer()}") == []
  end
end
