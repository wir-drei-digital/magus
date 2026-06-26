defmodule MagusWeb.WorkspaceChannelTest do
  use MagusWeb.ChannelCase, async: true

  import Magus.Generators

  alias MagusWeb.Rpc.RpcController
  alias MagusWeb.{UserSocket, WorkspaceChannel}

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

  defp connect_as(user) do
    token = Phoenix.Token.sign(MagusWeb.Endpoint, RpcController.socket_token_salt(), user.id)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    socket
  end

  describe "join" do
    test "members join via workspace read policies" do
      owner = subscribed_user()
      workspace = generate(workspace(actor: owner))

      member = generate(user())
      workspace_member(user_id: member.id, workspace_id: workspace.id)

      assert {:ok, _reply, _socket} =
               subscribe_and_join(
                 connect_as(member),
                 WorkspaceChannel,
                 "workspace:#{workspace.id}"
               )
    end

    test "non-members are rejected" do
      owner = subscribed_user()
      workspace = generate(workspace(actor: owner))
      stranger = generate(user())

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 connect_as(stranger),
                 WorkspaceChannel,
                 "workspace:#{workspace.id}"
               )
    end
  end

  describe "file event bridging" do
    test "workspace file events arrive as file.<event> (frozen summary payload)" do
      owner = subscribed_user()
      workspace = generate(workspace(actor: owner))

      {:ok, _reply, _socket} =
        subscribe_and_join(connect_as(owner), WorkspaceChannel, "workspace:#{workspace.id}")

      # Through the real producer: BroadcastWorkspaceEvent fires on create.
      file = generate(file(actor: owner, workspace_id: workspace.id))
      file_id = file.id
      workspace_id = workspace.id

      assert_push "file.create", %{id: ^file_id, workspace_id: ^workspace_id, action: :created}
    end

    test "does not receive other workspaces' file events" do
      owner = subscribed_user()
      workspace = generate(workspace(actor: owner))
      other_workspace = generate(workspace(actor: owner))

      {:ok, _reply, _socket} =
        subscribe_and_join(connect_as(owner), WorkspaceChannel, "workspace:#{workspace.id}")

      other_file = generate(file(actor: owner, workspace_id: other_workspace.id))
      other_id = other_file.id

      refute_push "file.create", %{id: ^other_id}
    end
  end
end
