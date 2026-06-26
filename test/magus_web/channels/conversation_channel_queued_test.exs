defmodule MagusWeb.ConversationChannelQueuedTest do
  use MagusWeb.ChannelCase, async: true

  import Magus.Generators

  alias MagusWeb.Rpc.RpcController
  alias MagusWeb.{ConversationChannel, UserSocket}

  defp connect_as(user) do
    token = Phoenix.Token.sign(MagusWeb.Endpoint, RpcController.socket_token_salt(), user.id)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    socket
  end

  describe "chat:queued bridging" do
    setup do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      {:ok, _reply, socket} =
        subscribe_and_join(
          connect_as(user),
          ConversationChannel,
          "conversation:#{conversation.id}"
        )

      {:ok, user: user, conversation: conversation, socket: socket}
    end

    test "queued broadcasts are pushed to the client as queued.<event>", %{
      conversation: conversation
    } do
      MagusWeb.Endpoint.broadcast("chat:queued:#{conversation.id}", "enqueue_message", %{
        id: "m1",
        status: :queued,
        text: "later"
      })

      assert_push "queued.enqueue_message", %{id: "m1"}
    end

    test "forwards flush and remove queued lifecycle events", %{conversation: conversation} do
      MagusWeb.Endpoint.broadcast("chat:queued:#{conversation.id}", "flush_queued", %{id: "m2"})
      assert_push "queued.flush_queued", %{id: "m2"}

      MagusWeb.Endpoint.broadcast("chat:queued:#{conversation.id}", "remove_queued", %{id: "m3"})
      assert_push "queued.remove_queued", %{id: "m3"}
    end

    test "does not leak queued events from other conversations", %{user: user} do
      other = generate(conversation(actor: user))

      MagusWeb.Endpoint.broadcast("chat:queued:#{other.id}", "enqueue_message", %{id: "m4"})

      refute_push "queued.enqueue_message", %{id: "m4"}
    end
  end
end
