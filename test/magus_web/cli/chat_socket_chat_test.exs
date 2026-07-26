defmodule MagusWeb.Cli.ChatSocketChatTest do
  use Magus.DataCase, async: false
  import Magus.Generators
  import Mox

  alias MagusWeb.Cli.ChatSocket

  setup :set_mox_global

  test "chat persists a user message carrying caller_session_id + local_tools metadata" do
    user = generate(user())
    {:ok, conv} = Magus.Chat.create_conversation(%{chat_mode: :chat}, actor: user)

    state = %{
      user: user,
      session_id: "s-1",
      conversation_id: conv.id,
      accepted_tools: ["read_file"],
      pending: %{}
    }

    frame =
      Jason.encode!(%{"type" => "chat", "v" => 1, "session_id" => "s-1", "text" => "hi there"})

    assert {:ok, _state} = ChatSocket.handle_in({frame, [opcode: :text]}, state)

    # The user message is persisted with our metadata (assert via the Chat read API).
    messages = Magus.Chat.message_history!(conv.id, actor: user) |> Enum.to_list()
    user_msg = Enum.find(messages, &(&1.role == :user and &1.text == "hi there"))
    assert user_msg
    assert user_msg.metadata["caller_session_id"] == "s-1"
    assert user_msg.metadata["local_tools"] == ["read_file"]
  end
end
