defmodule MagusWeb.Cli.ChatSocketStreamTest do
  use ExUnit.Case, async: true
  alias MagusWeb.Cli.ChatSocket

  defp state,
    do: %{user: nil, session_id: "s", conversation_id: "c", accepted_tools: [], pending: %{}}

  defp broadcast(payload),
    do: %Phoenix.Socket.Broadcast{topic: "agents:c", event: "agent_signal", payload: payload}

  defp push(payload) do
    assert {:push, {:text, json}, _} = ChatSocket.handle_info(broadcast(payload), state())
    Jason.decode!(json)
  end

  test "maps text.chunk to text.delta" do
    f = push(%{type: "text.chunk", message_id: "m1", delta: "Hel", text: "Hel"})
    assert f["type"] == "chat_stream"
    assert f["event"] == "text.delta"
    assert f["data"]["delta"] == "Hel"
  end

  test "maps text.complete to text.done" do
    f = push(%{type: "text.complete", message_id: "m1", text: "Hello", usage: %{}})
    assert f["event"] == "text.done"
    assert f["data"]["text"] == "Hello"
  end

  test "maps tool.start and tool.complete" do
    start =
      push(%{
        type: "tool.start",
        event_id: "e1",
        tool_name: "read_file",
        display_name: "Reading...",
        inputs: %{}
      })

    assert start["event"] == "tool.start"
    assert start["data"]["event_id"] == "e1"
    assert start["data"]["tool_name"] == "read_file"

    complete =
      push(%{
        type: "tool.complete",
        event_id: "e1",
        tool_name: "read_file",
        status: :success,
        output_summary: "3 lines",
        duration_ms: 0,
        error: nil
      })

    assert complete["event"] == "tool.complete"
    # Pins the :output_summary -> "summary" and atom-status -> string mapping
    # (the exact SseStreamer trap).
    assert complete["data"]["summary"] == "3 lines"
    assert complete["data"]["status"] == "success"
  end

  test "maps response.complete to turn.done" do
    f = push(%{type: "response.complete", triggering_message_id: "req-1"})
    assert f["event"] == "turn.done"
    assert f["data"]["message_id"] == "req-1"
  end

  test "maps error using the error_message field" do
    f =
      push(%{type: "error", message_id: "m1", error_type: :request_failed, error_message: "boom"})

    assert f["event"] == "error"
    assert f["data"]["message"] == "boom"
  end

  test "ignores unmapped signal types" do
    assert {:ok, _} =
             ChatSocket.handle_info(broadcast(%{type: "thinking.chunk", delta: "..."}), state())
  end
end
