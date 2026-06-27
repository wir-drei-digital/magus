defmodule MagusWeb.ConversationPresenceChannelTest do
  use MagusWeb.ChannelCase, async: true

  import Magus.Generators

  alias MagusWeb.Rpc.RpcController
  alias MagusWeb.{ConversationPresenceChannel, UserSocket}

  defp connect_as(user) do
    token = Phoenix.Token.sign(MagusWeb.Endpoint, RpcController.socket_token_salt(), user.id)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    socket
  end

  defp join_feed(user) do
    {:ok, _reply, socket} =
      subscribe_and_join(
        connect_as(user),
        ConversationPresenceChannel,
        "conversation_presence:#{user.id}"
      )

    socket
  end

  describe "join" do
    test "authorizes a user's own feed" do
      user = generate(user())

      assert {:ok, _reply, _socket} =
               subscribe_and_join(
                 connect_as(user),
                 ConversationPresenceChannel,
                 "conversation_presence:#{user.id}"
               )
    end

    test "rejects another user's feed" do
      user = generate(user())
      other = generate(user())

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 connect_as(user),
                 ConversationPresenceChannel,
                 "conversation_presence:#{other.id}"
               )
    end
  end

  describe "watch" do
    test "returns a snapshot keyed by the accessible watched conversations" do
      user = generate(user())
      conversation = generate(conversation(actor: user))
      socket = join_feed(user)

      push(socket, "watch", %{"conversation_ids" => [conversation.id]})

      conversation_id = conversation.id
      assert_push "presence.snapshot", %{conversations: snapshot}
      assert Map.has_key?(snapshot, conversation_id)
    end

    test "excludes conversations the user cannot access" do
      user = generate(user())
      stranger = generate(user())
      mine = generate(conversation(actor: user))
      theirs = generate(conversation(actor: stranger))
      socket = join_feed(user)

      push(socket, "watch", %{"conversation_ids" => [mine.id, theirs.id]})

      mine_id = mine.id
      theirs_id = theirs.id
      assert_push "presence.snapshot", %{conversations: snapshot}
      assert Map.has_key?(snapshot, mine_id)
      refute Map.has_key?(snapshot, theirs_id)
    end
  end

  describe "live updates" do
    test "pushes a presence.update on a diff for a watched conversation" do
      user = generate(user())
      conversation = generate(conversation(actor: user))
      socket = join_feed(user)

      push(socket, "watch", %{"conversation_ids" => [conversation.id]})
      assert_push "presence.snapshot", %{conversations: _}

      MagusWeb.Endpoint.broadcast(
        "presence:conversation:#{conversation.id}",
        "presence_diff",
        %{}
      )

      conversation_id = conversation.id
      assert_push "presence.update", %{conversation_id: ^conversation_id, viewers: _}
    end

    test "ignores diffs for conversations that are not being watched" do
      user = generate(user())
      watched = generate(conversation(actor: user))
      other = generate(conversation(actor: user))
      socket = join_feed(user)

      push(socket, "watch", %{"conversation_ids" => [watched.id]})
      assert_push "presence.snapshot", %{conversations: _}

      MagusWeb.Endpoint.broadcast(
        "presence:conversation:#{other.id}",
        "presence_diff",
        %{}
      )

      refute_push "presence.update", %{}
    end
  end
end
