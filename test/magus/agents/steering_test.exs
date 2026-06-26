defmodule Magus.Agents.SteeringTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Steering
  alias Magus.Chat

  setup do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{title: "s"}, actor: user)
    %{user: user, conversation: conversation}
  end

  test "promote_queued promotes all queued messages oldest-first",
       %{user: user, conversation: conversation} do
    {:ok, a} = Chat.enqueue_message(conversation.id, %{text: "a"}, actor: user)
    {:ok, b} = Chat.enqueue_message(conversation.id, %{text: "b"}, actor: user)

    promoted = Steering.promote_queued(conversation.id)

    assert Enum.map(promoted, & &1.id) == [a.id, b.id]
    assert Enum.all?(promoted, &(&1.status == :complete))
    assert Chat.list_queued_messages!(conversation.id, actor: user) == []
  end

  test "promote_queued returns [] when nothing queued",
       %{conversation: conversation} do
    assert Steering.promote_queued(conversation.id) == []
  end

  test "flush_conversation is a no-op when queue empty",
       %{conversation: conversation} do
    assert Steering.flush_conversation(conversation.id) == :ok
  end

  test "redispatch is a no-op when the message id does not exist",
       %{conversation: conversation} do
    assert Steering.redispatch(conversation.id, Ash.UUID.generate()) == :ok
  end

  test "send_now with no running agent flushes the queue",
       %{user: user, conversation: conversation} do
    {:ok, _} = Chat.enqueue_message(conversation.id, %{text: "x"}, actor: user)
    assert :ok = Steering.send_now(conversation.id)
    assert Chat.list_queued_messages!(conversation.id, actor: user) == []
  end
end
