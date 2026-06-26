defmodule MagusWeb.AgentChannelTest do
  use MagusWeb.ChannelCase, async: true

  import Magus.Generators

  alias MagusWeb.Rpc.RpcController
  alias MagusWeb.{AgentChannel, UserSocket}

  defp connect_as(user) do
    token = Phoenix.Token.sign(MagusWeb.Endpoint, RpcController.socket_token_salt(), user.id)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    socket
  end

  describe "join" do
    test "owners join via agent read policies" do
      user = generate(user())
      agent = custom_agent(user, %{name: "Mine"})

      assert {:ok, _reply, _socket} =
               subscribe_and_join(connect_as(user), AgentChannel, "agent:#{agent.id}")
    end

    test "strangers are rejected" do
      owner = generate(user())
      stranger = generate(user())
      agent = custom_agent(owner, %{name: "Private"})

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(connect_as(stranger), AgentChannel, "agent:#{agent.id}")
    end
  end

  describe "activity bridging" do
    test "activity.new arrives with a serialized summary (real producer)" do
      user = generate(user())
      agent = custom_agent(user, %{name: "Worker"})

      {:ok, _reply, _socket} =
        subscribe_and_join(connect_as(user), AgentChannel, "agent:#{agent.id}")

      {:ok, log} =
        Magus.Agents.create_activity_log(
          %{
            agent_id: agent.id,
            activity_type: :run_completed,
            summary: "Finished research"
          },
          actor: user
        )

      Magus.Agents.ActivityBroadcaster.broadcast_activity(log)

      log_id = log.id

      assert_push "activity.new", %{"activity" => activity}
      assert %{"id" => ^log_id, "summary" => "Finished research"} = activity
      assert activity["activity_type"] == "run_completed"
    end

    test "inbox and status hints pass through" do
      user = generate(user())
      agent = custom_agent(user, %{name: "Hinted"})

      {:ok, _reply, _socket} =
        subscribe_and_join(connect_as(user), AgentChannel, "agent:#{agent.id}")

      Magus.Agents.ActivityBroadcaster.broadcast_inbox_changed(agent.id, user.id)
      agent_id = agent.id
      assert_push "activity.inbox_changed", %{"agent_id" => ^agent_id}

      Magus.Agents.ActivityBroadcaster.broadcast_status_changed(agent.id, user.id, :running)
      assert_push "activity.status_changed", %{"agent_id" => ^agent_id, "status" => "running"}
    end
  end
end
