defmodule MagusWeb.Cli.ChatSocketMcpTest do
  use ExUnit.Case, async: true
  alias MagusWeb.Cli.ChatSocket

  defp state,
    do: %{
      user: nil,
      session_id: "s",
      conversation_id: "c",
      accepted_tools: ["read_file"],
      pending: %{}
    }

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

    frame =
      Jason.encode!(%{
        "type" => "mcp_result",
        "v" => 1,
        "call_id" => "call-1",
        "status" => "ok",
        "result" => %{"content" => "hello"}
      })

    assert {:ok, new_state} = ChatSocket.handle_in({frame, [opcode: :text]}, state)
    assert_receive {:mcp_result, "call-1", "ok", %{"content" => "hello"}, _error}
    refute Map.has_key?(new_state.pending, "call-1")
  end

  test "an mcp_result for an unknown call_id is ignored safely" do
    frame =
      Jason.encode!(%{
        "type" => "mcp_result",
        "call_id" => "ghost",
        "status" => "ok",
        "result" => %{}
      })

    assert {:ok, _state} = ChatSocket.handle_in({frame, [opcode: :text]}, state())
  end
end
