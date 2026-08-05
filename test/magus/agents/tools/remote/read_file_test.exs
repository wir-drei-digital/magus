defmodule Magus.Agents.Tools.Remote.ReadFileTest do
  # mutates Application env in the timeout cases
  use ExUnit.Case, async: false
  alias Magus.Agents.Tools.Remote.ReadFile
  alias Magus.Cli.ConnectionRegistry

  # Spawns a process that registers as `user_id`'s CLI connection for
  # `conversation_id` and runs `reply_fun.(from, call_id)` when it receives
  # the mcp_call. Returns once registration is confirmed.
  defp stub_handler(user_id, conversation_id \\ "conv-1", reply_fun) do
    test = self()

    spawn(fn ->
      :ok = ConnectionRegistry.register(user_id, conversation_id)
      send(test, :registered)

      receive do
        {:mcp_call, call_id, tool, params, from} ->
          send(test, {:got_call, tool, params})
          reply_fun.(from, call_id)
      end
    end)

    assert_receive :registered, 1_000
  end

  defp uid, do: "user-#{System.unique_integer([:positive])}"

  test "returns content on an ok result" do
    user_id = uid()

    stub_handler(user_id, fn from, call_id ->
      send(from, {:mcp_result, call_id, "ok", %{"content" => "hello\nworld"}, nil})
    end)

    assert {:ok, %{content: "hello\nworld", path: "a.txt"}} =
             ReadFile.run(%{"path" => "a.txt"}, %{acting_user_id: user_id})

    assert_receive {:got_call, "read_file", %{path: "a.txt"}}
  end

  test "routes by the server-side acting user, never to another user's connection" do
    victim_id = uid()

    stub_handler(victim_id, fn from, call_id ->
      send(from, {:mcp_result, call_id, "ok", %{"content" => "VICTIM PRIVATE KEY"}, nil})
    end)

    # An attacker's turn carries the attacker's acting_user_id (set server-side
    # by Preflight); nothing client-supplied can redirect it to the victim —
    # including a legacy-style caller_session_id decoy smuggled into context,
    # which must be dead weight (pins that no fallback ever reads it).
    assert {:ok, %{error: msg}} =
             ReadFile.run(%{"path" => "~/.ssh/id_rsa"}, %{
               acting_user_id: uid(),
               caller_session_id: victim_id
             })

    assert msg =~ "No active local connection"
    refute_receive {:got_call, _, _}, 100
  end

  test "prefers the connection on the turn's conversation over a newer one" do
    user_id = uid()

    stub_handler(user_id, "conv-laptop", fn from, call_id ->
      send(from, {:mcp_result, call_id, "ok", %{"content" => "laptop"}, nil})
    end)

    # A newer connection on another conversation must not steal the call.
    stub_handler(user_id, "conv-remote", fn from, call_id ->
      send(from, {:mcp_result, call_id, "ok", %{"content" => "remote box"}, nil})
    end)

    assert {:ok, %{content: "laptop"}} =
             ReadFile.run(%{"path" => "a.txt"}, %{
               acting_user_id: user_id,
               conversation_id: "conv-laptop"
             })
  end

  test "no live connection is a terminal ok-wrapped error (not retryable)" do
    assert {:ok, %{error: msg}} = ReadFile.run(%{"path" => "a.txt"}, %{acting_user_id: uid()})
    assert msg =~ "No active local connection"
  end

  test "denied maps to a terminal error" do
    user_id = uid()

    stub_handler(user_id, fn from, call_id ->
      send(from, {:mcp_result, call_id, "denied", %{}, nil})
    end)

    assert {:ok, %{error: msg}} = ReadFile.run(%{"path" => "secret"}, %{acting_user_id: user_id})
    assert msg =~ "denied"
  end

  test "missing acting_user_id is terminal" do
    assert {:ok, %{error: _}} = ReadFile.run(%{"path" => "a.txt"}, %{})
  end

  test "a missing or blank path is terminal and never contacts the connection" do
    user_id = uid()

    stub_handler(user_id, fn from, call_id ->
      send(from, {:mcp_result, call_id, "ok", %{}, nil})
    end)

    assert {:ok, %{error: _}} = ReadFile.run(%{}, %{acting_user_id: user_id})
    assert {:ok, %{error: _}} = ReadFile.run(%{"path" => ""}, %{acting_user_id: user_id})
    refute_receive {:got_call, _, _}, 100
  end

  test "an unrecognized result status is terminal, not a hang until timeout" do
    Application.put_env(:magus, :remote_tool_timeout_ms, 500)
    on_exit(fn -> Application.delete_env(:magus, :remote_tool_timeout_ms) end)

    user_id = uid()

    stub_handler(user_id, fn from, call_id ->
      send(from, {:mcp_result, call_id, "partial", %{}, nil})
    end)

    started = System.monotonic_time(:millisecond)
    assert {:ok, %{error: _}} = ReadFile.run(%{"path" => "a.txt"}, %{acting_user_id: user_id})
    # Returned from the catch-all clause, not by burning the full timeout.
    assert System.monotonic_time(:millisecond) - started < 400
  end

  test "times out when the handler never replies" do
    Application.put_env(:magus, :remote_tool_timeout_ms, 50)
    on_exit(fn -> Application.delete_env(:magus, :remote_tool_timeout_ms) end)

    user_id = uid()
    stub_handler(user_id, fn _from, _call_id -> Process.sleep(1_000) end)

    assert {:ok, %{error: msg}} = ReadFile.run(%{"path" => "a.txt"}, %{acting_user_id: user_id})
    assert msg =~ "Timed out"
  end
end
