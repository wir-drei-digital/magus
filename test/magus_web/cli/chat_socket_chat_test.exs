defmodule MagusWeb.Cli.ChatSocketChatTest do
  use Magus.DataCase, async: false
  import Magus.Generators
  import Mox

  alias MagusWeb.Cli.ChatSocket

  setup :set_mox_global

  defp chat_frame(text) do
    %{"type" => "chat", "v" => 1}
    |> then(fn f -> if text, do: Map.put(f, "text", text), else: f end)
    |> Jason.encode!()
  end

  test "chat persists a user message carrying only local_tools metadata" do
    user = generate(user())
    {:ok, conv} = Magus.Chat.create_conversation(%{chat_mode: :chat}, actor: user)

    state = %{
      user: user,
      conversation_id: conv.id,
      accepted_tools: ["read_file"],
      pending: %{}
    }

    assert {:ok, _state} = ChatSocket.handle_in({chat_frame("hi there"), [opcode: :text]}, state)

    messages = Magus.Chat.message_history!(conv.id, actor: user) |> Enum.to_list()
    user_msg = Enum.find(messages, &(&1.role == :user and &1.text == "hi there"))
    assert user_msg
    assert user_msg.metadata["local_tools"] == ["read_file"]
    # No routing identity in metadata: the reverse tunnel resolves the caller
    # from the server-side acting_user_id, so there is nothing to forge.
    refute Map.has_key?(user_msg.metadata, "caller_session_id")
  end

  test "chat before hello is answered with an error frame, not silently dropped" do
    user = generate(user())
    {:ok, state} = ChatSocket.init(%{user: user})

    assert {:push, {:text, json}, _state} =
             ChatSocket.handle_in({chat_frame("hi"), [opcode: :text]}, state)

    reply = Jason.decode!(json)
    assert reply["type"] == "error"
    assert reply["code"] == "not_ready"
  end

  test "chat without a text field is answered with an error frame" do
    user = generate(user())

    state = %{user: user, conversation_id: Ecto.UUID.generate(), accepted_tools: [], pending: %{}}

    assert {:push, {:text, json}, _state} =
             ChatSocket.handle_in({chat_frame(nil), [opcode: :text]}, state)

    assert Jason.decode!(json)["type"] == "error"
  end
end
