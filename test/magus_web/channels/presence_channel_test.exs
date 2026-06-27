defmodule MagusWeb.PresenceChannelTest do
  use MagusWeb.ChannelCase, async: true

  import Magus.Generators

  alias MagusWeb.Rpc.RpcController
  alias MagusWeb.{PresenceChannel, UserSocket}

  defp connect_as(user) do
    token = Phoenix.Token.sign(MagusWeb.Endpoint, RpcController.socket_token_salt(), user.id)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    socket
  end

  describe "join (brain page)" do
    test "authorizes via the page read policy and pushes the viewer list" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      page = brain_page(brain_id: brain.id, user_id: user.id)

      {:ok, _reply, _socket} =
        subscribe_and_join(connect_as(user), PresenceChannel, "viewers:page:#{page.id}")

      user_id = user.id
      assert_push "presence.state", %{viewers: viewers}
      assert Enum.any?(viewers, &(&1.user_id == user_id))
    end

    test "rejects a user without access to the page" do
      owner = generate(user())
      stranger = generate(user())
      brain = generate(brain(user_id: owner.id))
      page = brain_page(brain_id: brain.id, user_id: owner.id)

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 connect_as(stranger),
                 PresenceChannel,
                 "viewers:page:#{page.id}"
               )
    end
  end

  describe "join (draft)" do
    test "authorizes via the draft read policy and pushes the viewer list" do
      user = generate(user())
      draft = draft(user_id: user.id)

      {:ok, _reply, _socket} =
        subscribe_and_join(connect_as(user), PresenceChannel, "viewers:draft:#{draft.id}")

      user_id = user.id
      assert_push "presence.state", %{viewers: viewers}
      assert Enum.any?(viewers, &(&1.user_id == user_id))
    end
  end

  describe "join (validation)" do
    test "rejects an unsupported resource type" do
      user = generate(user())

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 connect_as(user),
                 PresenceChannel,
                 "viewers:spreadsheet:#{Ecto.UUID.generate()}"
               )
    end
  end

  describe "live updates" do
    test "re-pushes the viewer list on a presence diff for the resource" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      page = brain_page(brain_id: brain.id, user_id: user.id)

      {:ok, _reply, _socket} =
        subscribe_and_join(connect_as(user), PresenceChannel, "viewers:page:#{page.id}")

      assert_push "presence.state", %{viewers: _}

      # Phoenix.Presence emits a presence_diff on the shared topic on
      # track/untrack; the channel must re-list and re-push.
      MagusWeb.Endpoint.broadcast("presence:page:#{page.id}", "presence_diff", %{})

      assert_push "presence.state", %{viewers: _}
    end
  end
end
