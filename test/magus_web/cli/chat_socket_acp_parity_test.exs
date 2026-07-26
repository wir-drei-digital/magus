# test/magus_web/cli/chat_socket_acp_parity_test.exs
#
# ACP server-side plan §3 (2026-06-22-magus-acp-server.md): the chat bridge is
# front-end-agnostic. An ACP editor peer speaks the SAME wire protocol as a
# terminal `magus chat` peer, so the server serves both identically with NO
# ACP-specific code. This test re-exercises the existing ChatSocket behaviour
# with ACP-framed input; it must pass with zero production changes.
defmodule MagusWeb.Cli.ChatSocketAcpParityTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  alias MagusWeb.Cli.ChatSocket

  @registry Magus.Cli.ConnectionRegistry

  defp initial_state(user),
    do: %{user: user, session_id: nil, conversation_id: nil, accepted_tools: [], pending: %{}}

  test "an ACP peer's hello is accepted identically to a terminal peer's" do
    user = generate(user())
    {:ok, state} = ChatSocket.init(initial_state(user))
    sid = "acp-#{System.unique_integer([:positive])}"

    frame =
      Jason.encode!(%{
        "type" => "hello",
        "v" => 1,
        "session_id" => sid,
        # An editor advertises the SAME capability shape as the TUI.
        "capabilities" => %{"local_tools" => ["read_file"]},
        "conversation" => %{"new" => true}
      })

    assert {:push, {:text, json}, new_state} =
             ChatSocket.handle_in({frame, [opcode: :text]}, state)

    reply = Jason.decode!(json)
    assert reply["type"] == "server_hello"
    assert reply["accepted_tools"] == ["read_file"]
    assert is_binary(reply["conversation_id"])

    # The session is registered for reverse-tunnel routing exactly as for a TUI peer.
    assert [{pid, _}] = Registry.lookup(@registry, sid)
    assert pid == self()
    assert new_state.conversation_id == reply["conversation_id"]
  end

  test "an mcp_result is routed back regardless of how the peer produced it" do
    # The server cannot distinguish an editor's fs/read_text_file result from a
    # terminal File.read result — both arrive as {status:"ok", result:{content}}
    # and reach the waiting proxy as the same 5-tuple.
    waiter = self()

    state = %{
      initial_state(nil)
      | session_id: "acp-x",
        conversation_id: "c",
        pending: %{"call-1" => waiter}
    }

    frame =
      Jason.encode!(%{
        "type" => "mcp_result",
        "v" => 1,
        "call_id" => "call-1",
        "status" => "ok",
        "result" => %{"content" => "defmodule App"}
      })

    assert {:ok, new_state} = ChatSocket.handle_in({frame, [opcode: :text]}, state)
    assert_receive {:mcp_result, "call-1", "ok", %{"content" => "defmodule App"}, _error}
    refute Map.has_key?(new_state.pending, "call-1")
  end
end
