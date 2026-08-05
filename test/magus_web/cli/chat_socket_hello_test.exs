defmodule MagusWeb.Cli.ChatSocketHelloTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  alias Magus.Cli.ConnectionRegistry
  alias MagusWeb.Cli.ChatSocket

  defp hello_frame(tools, conversation \\ %{"new" => true}) do
    Jason.encode!(%{
      "type" => "hello",
      "v" => 1,
      # A client-supplied session id is protocol noise: the server must ignore
      # it — routing identity is the authenticated user, set at the upgrade.
      "session_id" => "client-chosen-#{System.unique_integer([:positive])}",
      "capabilities" => %{"local_tools" => tools},
      "conversation" => conversation
    })
  end

  test "hello creates a conversation, registers the connection, and replies server_hello" do
    user = generate(user())
    {:ok, state} = ChatSocket.init(%{user: user})

    assert {:push, {:text, json}, new_state} =
             ChatSocket.handle_in(
               {hello_frame(["read_file", "exec_command"]), [opcode: :text]},
               state
             )

    reply = Jason.decode!(json)
    assert reply["type"] == "server_hello"
    assert is_binary(reply["conversation_id"])
    # unknown tools are dropped (zero-trust): only read_file is accepted
    assert reply["accepted_tools"] == ["read_file"]

    assert new_state.conversation_id == reply["conversation_id"]
    # Registered under the AUTHENTICATED user id — nothing client-supplied.
    assert ConnectionRegistry.lookup(user.id) == self()
  end

  test "a second hello on the same connection is rejected" do
    user = generate(user())
    {:ok, state} = ChatSocket.init(%{user: user})

    assert {:push, {:text, _}, state} =
             ChatSocket.handle_in({hello_frame(["read_file"]), [opcode: :text]}, state)

    first_conversation = state.conversation_id

    assert {:push, {:text, json}, state} =
             ChatSocket.handle_in({hello_frame(["read_file"]), [opcode: :text]}, state)

    assert Jason.decode!(json)["type"] == "error"
    # The connection keeps its original conversation and single registration.
    assert state.conversation_id == first_conversation
    assert Registry.lookup(ConnectionRegistry, user.id) |> length() == 1
  end

  test "resume of a conversation the user does not own is rejected and nothing is registered" do
    owner = generate(user())
    other = generate(user())
    {:ok, conv} = Magus.Chat.create_conversation(%{chat_mode: :chat}, actor: owner)

    {:ok, state} = ChatSocket.init(%{user: other})

    assert {:push, {:text, json}, _state} =
             ChatSocket.handle_in(
               {hello_frame(["read_file"], %{"resume" => conv.id}), [opcode: :text]},
               state
             )

    assert Jason.decode!(json)["type"] == "error"
    assert ConnectionRegistry.lookup(other.id) == nil
  end
end
