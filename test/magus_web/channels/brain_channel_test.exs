defmodule MagusWeb.BrainChannelTest do
  use MagusWeb.ChannelCase, async: true

  import Magus.Generators

  alias MagusWeb.Rpc.RpcController
  alias MagusWeb.{BrainChannel, UserSocket}

  defp connect_as(user) do
    token = Phoenix.Token.sign(MagusWeb.Endpoint, RpcController.socket_token_salt(), user.id)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    socket
  end

  describe "join" do
    test "owners join via brain read policies" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))

      assert {:ok, _reply, _socket} =
               subscribe_and_join(connect_as(user), BrainChannel, "brain_updates:#{brain.id}")
    end

    test "strangers are rejected" do
      owner = generate(user())
      stranger = generate(user())
      brain = generate(brain(user_id: owner.id))

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(connect_as(stranger), BrainChannel, "brain_updates:#{brain.id}")
    end
  end

  describe "event bridging (real producers)" do
    setup do
      user = generate(user())
      brain = generate(brain(user_id: user.id))

      {:ok, _reply, _socket} =
        subscribe_and_join(connect_as(user), BrainChannel, "brain_updates:#{brain.id}")

      {:ok, user: user, brain: brain}
    end

    test "page create and rename arrive as tree hints", %{user: user, brain: brain} do
      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Notes"}, actor: user)
      page_id = page.id

      assert_push "page.created", %{"page_id" => ^page_id}

      {:ok, _} = Magus.Brain.update_page_title(page, %{title: "Renamed"}, actor: user)
      assert_push "page.updated", %{"page_id" => ^page_id}
    end

    test "trash (update) and hard destroy arrive as tree hints", %{user: user, brain: brain} do
      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Doomed"}, actor: user)
      page_id = page.id
      assert_push "page.created", %{"page_id" => ^page_id}

      # soft_delete is an :update action → page.updated (the SPA refetches
      # the tree on any page.* hint); only hard destroy emits page.deleted.
      {:ok, trashed} = Magus.Brain.soft_delete_page(page, actor: user)
      assert_push "page.updated", %{"page_id" => ^page_id}

      :ok = Magus.Brain.destroy_page(trashed, actor: user)
      assert_push "page.deleted", %{"page_id" => ^page_id}
    end

    test "body updates carry the new lock version", %{user: user, brain: brain} do
      page = brain_page(brain_id: brain.id, user_id: user.id)
      page_id = page.id

      {:ok, current} = Magus.Brain.get_page(page.id, actor: user)

      {:ok, updated} =
        Magus.Brain.update_page_body(
          current,
          %{body: "# Live", base_version: current.lock_version},
          actor: user
        )

      lock_version = updated.lock_version

      assert_push "page.body_updated", %{
        "page_id" => ^page_id,
        "lock_version" => ^lock_version,
        "source" => "user"
      }
    end
  end
end
