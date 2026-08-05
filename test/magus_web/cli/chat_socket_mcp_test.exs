defmodule MagusWeb.Cli.ChatSocketMcpTest do
  use ExUnit.Case, async: true
  alias MagusWeb.Cli.ChatSocket

  defp state,
    do: %{
      user: nil,
      conversation_id: "c",
      accepted_tools: ["read_file"],
      pending: %{}
    }

  defp result_frame(overrides) do
    Map.merge(
      %{"type" => "mcp_result", "v" => 1, "call_id" => "call-1", "status" => "ok"},
      overrides
    )
    |> Jason.encode!()
  end

  test "an mcp_call message is pushed as a frame and the waiter is tracked" do
    waiter = self()

    assert {:push, {:text, json}, new_state} =
             ChatSocket.handle_info(
               {:mcp_call, "call-1", "read_file", %{path: "a.txt"}, waiter},
               state()
             )

    frame = Jason.decode!(json)
    assert frame["type"] == "mcp_call"
    assert frame["call_id"] == "call-1"
    assert frame["tool_name"] == "read_file"
    assert frame["params"] == %{"path" => "a.txt"}
    assert new_state.pending["call-1"] == waiter
  end

  test "an mcp_result frame is routed back to the waiting process and untracked" do
    waiter = self()
    state = %{state() | pending: %{"call-1" => waiter}}

    frame = result_frame(%{"result" => %{"content" => "hello"}})

    assert {:ok, new_state} = ChatSocket.handle_in({frame, [opcode: :text]}, state)
    assert_receive {:mcp_result, "call-1", "ok", %{"content" => "hello"}, _error}
    refute Map.has_key?(new_state.pending, "call-1")
  end

  test "an mcp_result for an unknown call_id is ignored safely" do
    frame = result_frame(%{"call_id" => "ghost"})
    assert {:ok, _state} = ChatSocket.handle_in({frame, [opcode: :text]}, state())
  end

  # The wire is untrusted: malformed shapes are normalized at this boundary so
  # the waiting proxy tool can never crash (a raise would be classified as
  # retryable by the ReAct loop and re-prompt the user's machine) or hang.
  test "a non-map result is normalized to an empty map" do
    state = %{state() | pending: %{"call-1" => self()}}
    frame = result_frame(%{"result" => "not-a-map"})

    assert {:ok, _} = ChatSocket.handle_in({frame, [opcode: :text]}, state)
    assert_receive {:mcp_result, "call-1", "ok", %{}, _error}
  end

  test "an unrecognized status is normalized to error" do
    state = %{state() | pending: %{"call-1" => self()}}
    frame = result_frame(%{"status" => "partial"})

    assert {:ok, _} = ChatSocket.handle_in({frame, [opcode: :text]}, state)
    assert_receive {:mcp_result, "call-1", "error", %{}, _error}
  end

  test "a bare string error is wrapped into the map shape the proxy reads" do
    state = %{state() | pending: %{"call-1" => self()}}
    frame = result_frame(%{"status" => "error", "error" => "boom"})

    assert {:ok, _} = ChatSocket.handle_in({frame, [opcode: :text]}, state)
    assert_receive {:mcp_result, "call-1", "error", %{}, %{"message" => "boom"}}
  end

  test "pending entries are dropped when their waiter dies" do
    waiter = self()

    {:push, _frame, state} =
      ChatSocket.handle_info(
        {:mcp_call, "call-1", "read_file", %{path: "a.txt"}, waiter},
        state()
      )

    assert {:ok, new_state} =
             ChatSocket.handle_info({:DOWN, make_ref(), :process, waiter, :normal}, state)

    assert new_state.pending == %{}
  end
end
