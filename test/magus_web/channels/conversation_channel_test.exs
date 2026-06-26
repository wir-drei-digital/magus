defmodule MagusWeb.ConversationChannelTest do
  use MagusWeb.ChannelCase, async: true

  import Magus.Generators

  alias MagusWeb.Rpc.RpcController
  alias MagusWeb.{ConversationChannel, UserSocket}

  defp connect_as(user) do
    token = Phoenix.Token.sign(MagusWeb.Endpoint, RpcController.socket_token_salt(), user.id)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    socket
  end

  describe "join" do
    test "authorizes via conversation read policies" do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      assert {:ok, _reply, _socket} =
               subscribe_and_join(
                 connect_as(user),
                 ConversationChannel,
                 "conversation:#{conversation.id}"
               )
    end

    test "rejects users without access to the conversation" do
      owner = generate(user())
      stranger = generate(user())
      conversation = generate(conversation(actor: owner))

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 connect_as(stranger),
                 ConversationChannel,
                 "conversation:#{conversation.id}"
               )
    end
  end

  describe "bridging" do
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

    test "forwards agent signals under their own type", %{conversation: conversation} do
      MagusWeb.Endpoint.broadcast("agents:#{conversation.id}", "agent_signal", %{
        type: "text.chunk",
        message_id: "m-1",
        text: "He",
        delta: "He"
      })

      assert_push "text.chunk", %{message_id: "m-1", delta: "He"}
    end

    test "forwards tool signals", %{conversation: conversation} do
      MagusWeb.Endpoint.broadcast("agents:#{conversation.id}", "agent_signal", %{
        type: "tool.start",
        event_id: "ev-1",
        tool_name: "web_search",
        display_name: "Web Search",
        inputs: %{query: "hi"}
      })

      assert_push "tool.start", %{event_id: "ev-1", tool_name: "web_search"}
    end

    test "forwards message persistence events as message.<action>", %{
      conversation: conversation
    } do
      MagusWeb.Endpoint.broadcast("chat:messages:#{conversation.id}", "create", %{
        id: "m-2",
        text: "hello"
      })

      assert_push "message.create", %{id: "m-2", text: "hello"}
    end

    test "forwards message deletions from their dedicated topic", %{
      conversation: conversation
    } do
      MagusWeb.Endpoint.broadcast("chat:message_deletes:#{conversation.id}", "destroy", %{
        id: "m-9"
      })

      assert_push "message.destroy", %{id: "m-9"}
    end

    test "forwards typing events", %{conversation: conversation} do
      MagusWeb.Endpoint.broadcast("chat:typing:#{conversation.id}", "user_typing", %{
        user_id: "u-1",
        is_typing: true
      })

      assert_push "typing.user_typing", %{user_id: "u-1", is_typing: true}
    end

    test "pushes access.revoked and shuts down", %{conversation: conversation, socket: socket} do
      Process.monitor(socket.channel_pid)

      MagusWeb.Endpoint.broadcast("chat:access:#{conversation.id}", "access_revoked", %{
        conversation_id: conversation.id
      })

      assert_push "access.revoked", %{conversation_id: _}
      assert_receive {:DOWN, _ref, :process, _pid, _reason}
    end

    test "does not leak signals from other conversations", %{user: user} do
      other = generate(conversation(actor: user))

      MagusWeb.Endpoint.broadcast("agents:#{other.id}", "agent_signal", %{
        type: "text.chunk",
        message_id: "m-3",
        text: "x",
        delta: "x"
      })

      refute_push "text.chunk", %{message_id: "m-3"}
    end

    # End-to-end through the real producer: Draft create broadcasts the full
    # struct on drafts:conversation:<id>; the channel must reshape it into a
    # JSON-safe summary. The summary is content-free (no title/body) because
    # draft read policies are narrower than conversation read — clients
    # refetch via the policy-gated get_draft.
    test "forwards draft lifecycle events with a content-free summary", %{
      user: user,
      conversation: conversation
    } do
      {:ok, draft} =
        Magus.Drafts.create_draft(conversation.id, "Secret title", "Hello", user.id, actor: user)

      draft_id = draft.id

      assert_push "draft.created", %{"draft" => summary}
      assert %{"id" => ^draft_id, "version" => 1} = summary
      assert summary["conversation_id"] == conversation.id
      refute Map.has_key?(summary, "title")

      {:ok, _} = Magus.Drafts.update_draft_title(draft, "Renamed", actor: user)
      assert_push "draft.updated", %{"draft" => %{"id" => ^draft_id}}
    end
  end

  describe "outbound typing" do
    test "broadcasts user_typing in collaborative conversations (frozen shape)" do
      user = generate(user())
      conversation = generate(conversation(actor: user))
      {:ok, conversation} = Magus.Chat.enable_multiplayer(conversation, actor: user)

      {:ok, _reply, socket} =
        subscribe_and_join(
          connect_as(user),
          ConversationChannel,
          "conversation:#{conversation.id}"
        )

      push(socket, "typing", %{"is_typing" => true})

      # The channel is itself subscribed to chat:typing, so the broadcast
      # comes straight back as a push — same shape LiveView consumes.
      user_id = user.id
      assert_push "typing.user_typing", %{user_id: ^user_id, is_typing: true, user_name: _}
    end

    test "does not broadcast for non-collaborative conversations" do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      {:ok, _reply, socket} =
        subscribe_and_join(
          connect_as(user),
          ConversationChannel,
          "conversation:#{conversation.id}"
        )

      push(socket, "typing", %{"is_typing" => true})

      refute_push "typing.user_typing", %{}
    end
  end

  describe "cancel_response" do
    test "stops the turn and posts a 'Response cancelled' event" do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      {:ok, _reply, socket} =
        subscribe_and_join(
          connect_as(user),
          ConversationChannel,
          "conversation:#{conversation.id}"
        )

      ref = push(socket, "cancel_response", %{})
      assert_reply ref, :ok

      # create_event_message! publishes on chat:messages, which the channel
      # bridges back as message.create_event (no agent running in the test, so
      # the message.cancel signal is a no-op).
      assert_push "message.create_event", _payload
    end
  end
end
