defmodule Magus.MCP.SupervisorTest do
  use ExUnit.Case, async: true

  test "registry and dynamic supervisor are running" do
    assert is_pid(Process.whereis(Magus.MCP.ClientRegistry))
    assert is_pid(Process.whereis(Magus.MCP.ClientDynamicSupervisor))
  end
end
