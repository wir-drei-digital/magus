# test/magus_web/cli/chat_socket_hello_test.exs
defmodule MagusWeb.Cli.ChatSocketHelloTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  alias MagusWeb.Cli.ChatSocket

  @registry Magus.Cli.ConnectionRegistry

  defp initial_state(user),
    do: %{user: user, session_id: nil, conversation_id: nil, accepted_tools: []}

  defp hello_frame(session_id, tools, conversation \\ %{"new" => true}) do
    Jason.encode!(%{
      "type" => "hello",
      "v" => 1,
      "session_id" => session_id,
      "capabilities" => %{"local_tools" => tools},
      "conversation" => conversation
    })
  end

  test "hello creates a conversation, registers the session, and replies server_hello" do
    user = generate(user())
    sid = "s-#{System.unique_integer([:positive])}"

    {:ok, state} = ChatSocket.init(initial_state(user))

    assert {:push, {:text, json}, new_state} =
             ChatSocket.handle_in(
               {hello_frame(sid, ["read_file", "exec_command"]), [opcode: :text]},
               state
             )

    reply = Jason.decode!(json)
    assert reply["type"] == "server_hello"
    assert is_binary(reply["conversation_id"])
    # unknown tools are dropped (zero-trust): only read_file is accepted
    assert reply["accepted_tools"] == ["read_file"]

    assert new_state.conversation_id == reply["conversation_id"]
    # The registry key is namespaced by the authenticated user (tenant isolation).
    assert [{pid, _}] = Registry.lookup(@registry, "#{user.id}:#{sid}")
    assert pid == self()
  end

  test "resume of a conversation the user does not own is rejected" do
    owner = generate(user())
    other = generate(user())
    {:ok, conv} = Magus.Chat.create_conversation(%{chat_mode: :chat}, actor: owner)

    {:ok, state} = ChatSocket.init(initial_state(other))
    sid = "s-#{System.unique_integer([:positive])}"

    assert {:push, {:text, json}, _state} =
             ChatSocket.handle_in(
               {hello_frame(sid, ["read_file"], %{"resume" => conv.id}), [opcode: :text]},
               state
             )

    assert Jason.decode!(json)["type"] == "error"
    assert Registry.lookup(@registry, "#{other.id}:#{sid}") == []
  end
end
