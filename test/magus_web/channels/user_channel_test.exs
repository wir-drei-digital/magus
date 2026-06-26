defmodule MagusWeb.UserChannelTest do
  use MagusWeb.ChannelCase, async: true

  import Magus.Generators

  alias MagusWeb.Rpc.RpcController
  alias MagusWeb.{UserChannel, UserSocket}

  defp subscribed_user do
    # Once the free plan exists, registration auto-subscribes new users — so
    # the explicit create below only matters for the first user of a test
    # run and is allowed to fail on the unique index afterwards.
    free_plan = ensure_free_plan()
    user = generate(user())

    case Magus.Usage.create_user_subscription(
           %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
           authorize?: false
         ) do
      {:ok, _subscription} -> :ok
      {:error, _already_subscribed} -> :ok
    end

    user
  end

  defp sign_token(user_id) do
    Phoenix.Token.sign(MagusWeb.Endpoint, RpcController.socket_token_salt(), user_id)
  end

  describe "UserSocket.connect/3" do
    test "rejects missing or invalid tokens" do
      assert :error = connect(UserSocket, %{})
      assert :error = connect(UserSocket, %{"token" => "garbage"})
    end

    test "accepts a valid token and assigns the user id" do
      user = generate(user())
      assert {:ok, socket} = connect(UserSocket, %{"token" => sign_token(user.id)})
      assert socket.assigns.user_id == user.id
    end
  end

  describe "join" do
    test "is limited to the socket's own user topic" do
      user = generate(user())
      {:ok, socket} = connect(UserSocket, %{"token" => sign_token(user.id)})

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, UserChannel, "user:#{Ash.UUID.generate()}")
    end

    test "succeeds for the matching topic" do
      user = generate(user())
      {:ok, socket} = connect(UserSocket, %{"token" => sign_token(user.id)})

      assert {:ok, _reply, _socket} = subscribe_and_join(socket, UserChannel, "user:#{user.id}")
    end
  end

  describe "notification bridging" do
    test "forwards notifications:<user_id> broadcasts as notification.<event> pushes" do
      user = generate(user())
      {:ok, socket} = connect(UserSocket, %{"token" => sign_token(user.id)})
      {:ok, _reply, _socket} = subscribe_and_join(socket, UserChannel, "user:#{user.id}")

      MagusWeb.Endpoint.broadcast(Magus.Notifications.topic(user.id), "create", %{
        id: "n-1",
        title: "Hello",
        notification_type: :system
      })

      assert_push "notification.create", %{id: "n-1", title: "Hello"}
    end

    test "bridges a real Notification create (locks the producer → bridge contract)" do
      user = generate(user())
      {:ok, socket} = connect(UserSocket, %{"token" => sign_token(user.id)})
      {:ok, _reply, _socket} = subscribe_and_join(socket, UserChannel, "user:#{user.id}")

      {:ok, notification} =
        Magus.Notifications.create_notification(
          %{title: "Build done", body: "All green", user_id: user.id},
          actor: user
        )

      notification_id = notification.id
      assert_push "notification.create", %{id: ^notification_id, title: "Build done"}
    end

    test "does not receive other users' notifications" do
      user = generate(user())
      other = generate(user())
      {:ok, socket} = connect(UserSocket, %{"token" => sign_token(user.id)})
      {:ok, _reply, _socket} = subscribe_and_join(socket, UserChannel, "user:#{user.id}")

      MagusWeb.Endpoint.broadcast(Magus.Notifications.topic(other.id), "create", %{id: "n-2"})

      refute_push "notification.create", %{id: "n-2"}
    end
  end

  describe "file + folder bridging (iteration 5)" do
    setup do
      user = subscribed_user()
      {:ok, socket} = connect(UserSocket, %{"token" => sign_token(user.id)})
      {:ok, _reply, _socket} = subscribe_and_join(socket, UserChannel, "user:#{user.id}")
      {:ok, user: user}
    end

    # Through the real producers: the File pub_sub payload is the Ash
    # notification (not JSON-encodable), so the bridge pushes id-only hints.
    test "file create/update/soft_delete arrive as file.<event> id hints", %{user: user} do
      file = generate(file(actor: user))
      file_id = file.id

      assert_push "file.create", %{"id" => ^file_id}

      {:ok, _} = Magus.Files.update_file(file, %{name: "renamed.txt"}, actor: user)
      assert_push "file.update", %{"id" => ^file_id}

      {:ok, _} = Magus.Files.soft_delete_file(file, actor: user)
      assert_push "file.soft_delete", %{"id" => ^file_id}
    end

    test "folder lifecycle arrives as folder.<event> id hints", %{user: user} do
      folder = generate(folder(actor: user, kind: :files))
      folder_id = folder.id

      assert_push "folder.create", %{"id" => ^folder_id}

      {:ok, _} = Magus.Chat.update_folder(folder, %{name: "Renamed"}, actor: user)
      assert_push "folder.update", %{"id" => ^folder_id}
    end

    test "does not receive other users' file events", %{user: _user} do
      other = subscribed_user()
      other_file = generate(file(actor: other))
      other_id = other_file.id

      refute_push "file.create", %{"id" => ^other_id}
    end
  end

  describe "usage bridging" do
    setup do
      user = generate(user())
      {:ok, socket} = connect(UserSocket, %{"token" => sign_token(user.id)})
      {:ok, _reply, _socket} = subscribe_and_join(socket, UserChannel, "user:#{user.id}")
      {:ok, user: user}
    end

    # Locks the producer → bridge contract: the workbench usage signal is the
    # same one the classic shell consumes; the SPA gets a data-less hint.
    test "forwards workbench usage_changed as a usage.changed push", %{user: user} do
      :ok = MagusWeb.Workbench.Signals.broadcast_usage_changed(user.id)
      assert_push "usage.changed", %{}
    end

    test "ignores other workbench_user signals on the same topic", %{user: user} do
      :ok = MagusWeb.Workbench.Signals.broadcast_favorites_changed(user.id)
      refute_push "usage.changed", %{}
    end

    test "does not receive other users' usage signals", %{user: _user} do
      other = generate(user())
      :ok = MagusWeb.Workbench.Signals.broadcast_usage_changed(other.id)
      refute_push "usage.changed", %{}
    end
  end
end
