defmodule Magus.Workspaces.WorkspaceAgentTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents, as: CustomAgents

  describe "workspace custom agents" do
    test "can create a custom agent in a workspace" do
      owner = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Test", slug: "test-agents"},
          actor: owner
        )

      {:ok, agent} =
        CustomAgents.create_custom_agent(
          %{name: "Workspace Agent", workspace_id: workspace.id},
          actor: owner
        )

      assert agent.workspace_id == workspace.id
      assert agent.name == "Workspace Agent"
    end

    test "non-member cannot create a custom agent in another workspace" do
      owner = generate(user())
      outsider = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Test", slug: "test-agent-create-deny"},
          actor: owner
        )

      assert {:error, %Ash.Error.Forbidden{}} =
               CustomAgents.create_custom_agent(
                 %{name: "Forbidden Agent", workspace_id: workspace.id},
                 actor: outsider
               )
    end

    test "workspace member can read workspace agents once shared to team" do
      owner = generate(user())
      member = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Test", slug: "test-agent-read"},
          actor: owner
        )

      {:ok, invite} =
        Magus.Workspaces.invite_member(workspace.id, member.email, actor: owner)

      {:ok, _} = Magus.Workspaces.accept_invite(invite.invite_token, actor: member)

      {:ok, agent} =
        CustomAgents.create_custom_agent(
          %{name: "Shared Agent", workspace_id: workspace.id},
          actor: owner
        )

      # Sharing creates the workspace-level resource_access grant that backs
      # the read policy under workspace_scoped_policies.
      {:ok, _} = CustomAgents.share_custom_agent_to_team(agent, actor: owner)

      assert {:ok, found} = CustomAgents.get_custom_agent(agent.id, actor: member)
      assert found.id == agent.id
    end

    test "workspace owner can update workspace agents" do
      owner = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Test", slug: "test-agent-update"},
          actor: owner
        )

      {:ok, agent} =
        CustomAgents.create_custom_agent(
          %{name: "Original Name", workspace_id: workspace.id},
          actor: owner
        )

      {:ok, updated} =
        CustomAgents.update_custom_agent(agent, %{name: "Updated Name"}, actor: owner)

      assert updated.name == "Updated Name"
    end

    test "workspace member (non-owner) cannot update workspace agents" do
      owner = generate(user())
      member = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Test", slug: "test-agent-member-update"},
          actor: owner
        )

      {:ok, invite} =
        Magus.Workspaces.invite_member(workspace.id, member.email, actor: owner)

      {:ok, _} = Magus.Workspaces.accept_invite(invite.invite_token, actor: member)

      {:ok, agent} =
        CustomAgents.create_custom_agent(
          %{name: "Workspace Agent", workspace_id: workspace.id},
          actor: owner
        )

      assert {:error, %Ash.Error.Forbidden{}} =
               CustomAgents.update_custom_agent(agent, %{name: "Hacked"}, actor: member)
    end

    test "non-member cannot read workspace agents" do
      owner = generate(user())
      outsider = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "Test", slug: "test-agent-deny"},
          actor: owner
        )

      {:ok, agent} =
        CustomAgents.create_custom_agent(
          %{name: "Secret Agent", workspace_id: workspace.id},
          actor: owner
        )

      assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
               CustomAgents.get_custom_agent(agent.id, actor: outsider)
    end

    test "personal agents remain unaffected" do
      user = generate(user())

      {:ok, agent} =
        CustomAgents.create_custom_agent(%{name: "My Personal Agent"}, actor: user)

      assert agent.workspace_id == nil
      assert {:ok, found} = CustomAgents.get_custom_agent(agent.id, actor: user)
      assert found.id == agent.id
    end
  end
end
