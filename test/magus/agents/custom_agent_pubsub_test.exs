defmodule Magus.Agents.CustomAgentPubsubTest do
  use Magus.ResourceCase, async: false

  describe "workspace pub_sub" do
    test "broadcasts on create when agent has workspace_id" do
      owner = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "T", slug: "ws-agent-pubsub-#{System.unique_integer([:positive])}"},
          actor: owner
        )

      MagusWeb.Endpoint.subscribe("workspaces:#{workspace.id}:agents")

      {:ok, agent} =
        Magus.Agents.create_custom_agent(
          %{name: "My Agent", workspace_id: workspace.id},
          actor: owner
        )

      assert_receive %Phoenix.Socket.Broadcast{
        topic: topic,
        payload: %{id: id, workspace_id: ws_id, action: :created}
      }

      assert topic == "workspaces:#{workspace.id}:agents"
      assert id == agent.id
      assert ws_id == workspace.id
    end

    test "broadcasts on update when agent has workspace_id" do
      owner = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "T", slug: "ws-agent-pubsub-upd-#{System.unique_integer([:positive])}"},
          actor: owner
        )

      {:ok, agent} =
        Magus.Agents.create_custom_agent(
          %{name: "My Agent", workspace_id: workspace.id},
          actor: owner
        )

      MagusWeb.Endpoint.subscribe("workspaces:#{workspace.id}:agents")

      {:ok, _updated} =
        Magus.Agents.update_custom_agent(agent, %{name: "Updated Agent"}, actor: owner)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: topic,
        payload: %{id: id, workspace_id: ws_id, action: :updated}
      }

      assert topic == "workspaces:#{workspace.id}:agents"
      assert id == agent.id
      assert ws_id == workspace.id
    end

    test "does not broadcast to workspace topic when agent has no workspace_id" do
      owner = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "T", slug: "ws-agent-pubsub-nil-#{System.unique_integer([:positive])}"},
          actor: owner
        )

      MagusWeb.Endpoint.subscribe("workspaces:#{workspace.id}:agents")

      {:ok, _agent} =
        Magus.Agents.create_custom_agent(
          %{name: "No Workspace Agent"},
          actor: owner
        )

      refute_receive %Phoenix.Socket.Broadcast{}, 200
    end
  end
end
