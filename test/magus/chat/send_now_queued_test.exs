defmodule Magus.Chat.SendNowQueuedTest do
  use Magus.ResourceCase, async: true

  alias Magus.Chat

  test "send_now_queued returns :ok and is callable through the domain" do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{title: "x"}, actor: user)
    {:ok, _} = Chat.enqueue_message(conversation.id, %{text: "a"}, actor: user)

    # No running agent in this test => Steering.send_now falls back to flush.
    assert {:ok, :ok} = Chat.send_now_queued(conversation.id, actor: user)
  end

  test "send_now_queued denies a non-member actor" do
    owner = generate(user())
    outsider = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{title: "x"}, actor: owner)
    {:ok, _} = Chat.enqueue_message(conversation.id, %{text: "a"}, actor: owner)

    assert {:error, _} = Chat.send_now_queued(conversation.id, actor: outsider)
  end
end
