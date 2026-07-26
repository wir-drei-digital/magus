defmodule Magus.Agents.Tools.Remote.ReadFileTest do
  # mutates Application env in the timeout case
  use ExUnit.Case, async: false
  alias Magus.Agents.Tools.Remote.ReadFile

  @registry Magus.Cli.ConnectionRegistry

  # Spawns a process that registers under `sid` and runs `reply_fun.(from, call_id)`
  # when it receives the mcp_call. Returns once registration is confirmed.
  defp stub_handler(sid, reply_fun) do
    test = self()

    spawn(fn ->
      {:ok, _} = Registry.register(@registry, sid, nil)
      send(test, :registered)

      receive do
        {:mcp_call, call_id, tool, params, from} ->
          send(test, {:got_call, tool, params})
          reply_fun.(from, call_id)
      end
    end)

    assert_receive :registered, 1_000
  end

  test "returns content on an ok result" do
    sid = "s-#{System.unique_integer([:positive])}"

    stub_handler(sid, fn from, call_id ->
      send(from, {:mcp_result, call_id, "ok", %{"content" => "hello\nworld"}, nil})
    end)

    assert {:ok, %{content: "hello\nworld", path: "a.txt"}} =
             ReadFile.run(%{"path" => "a.txt"}, %{caller_session_id: sid})

    assert_receive {:got_call, "read_file", %{path: "a.txt"}}
  end

  test "no live connection is a terminal ok-wrapped error (not retryable)" do
    assert {:ok, %{error: msg}} =
             ReadFile.run(%{"path" => "a.txt"}, %{caller_session_id: "missing"})

    assert msg =~ "No active local connection"
  end

  test "denied maps to a terminal error" do
    sid = "s-#{System.unique_integer([:positive])}"

    stub_handler(sid, fn from, call_id ->
      send(from, {:mcp_result, call_id, "denied", %{}, nil})
    end)

    assert {:ok, %{error: msg}} = ReadFile.run(%{"path" => "secret"}, %{caller_session_id: sid})
    assert msg =~ "denied"
  end

  test "missing caller_session_id is terminal" do
    assert {:ok, %{error: _}} = ReadFile.run(%{"path" => "a.txt"}, %{})
  end

  test "times out when the handler never replies" do
    Application.put_env(:magus, :remote_tool_timeout_ms, 50)
    on_exit(fn -> Application.delete_env(:magus, :remote_tool_timeout_ms) end)

    sid = "s-#{System.unique_integer([:positive])}"
    stub_handler(sid, fn _from, _call_id -> Process.sleep(1_000) end)

    assert {:ok, %{error: msg}} = ReadFile.run(%{"path" => "a.txt"}, %{caller_session_id: sid})
    assert msg =~ "Timed out"
  end
end
