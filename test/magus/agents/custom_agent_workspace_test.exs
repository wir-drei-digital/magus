defmodule Magus.Agents.CustomAgentWorkspaceTest do
  @moduledoc """
  Tests for the generic workspace-scoped policy on `Magus.Agents.CustomAgent`
  backed by `Magus.Workspaces.ResourceAccess` grants. Covers the shared
  policy macro, the extended `:my_agents` filter (personal plus grants),
  `share_to_team` / `unshare_from_team` grant sync, and destroy grant
  cleanup.
  """
  use Magus.ResourceCase, async: true

  alias Magus.Agents, as: CustomAgents
  alias Magus.Workspaces
  alias Magus.Workspaces.ResourceAccess

  require Ash.Query

  defp add_active_member(workspace, admin_user, invitee) do
    {:ok, invite} =
      Workspaces.invite_member(workspace.id, invitee.email, actor: admin_user)

    {:ok, membership} = Workspaces.accept_invite(invite.invite_token, actor: invitee)
    membership
  end

  defp grant!(attrs) do
    {:ok, grant} =
      ResourceAccess
      |> Ash.Changeset.for_create(:grant, attrs)
      |> Ash.create(authorize?: false)

    grant
  end

  defp grants_for(agent) do
    ResourceAccess
    |> Ash.Query.for_read(:for_resource, %{resource_type: :custom_agent, resource_id: agent.id})
    |> Ash.read!(authorize?: false)
  end

  describe "workspace scoping" do
    setup do
      creator = generate(user())
      stranger = generate(user())
      ensure_workspace_plan(creator)

      {:ok, workspace} =
        Workspaces.create_workspace(
          %{name: "T", slug: "t-agent-#{System.unique_integer([:positive])}"},
          actor: creator
        )

      %{creator: creator, stranger: stranger, workspace: workspace}
    end

    test "creator can read their own workspace agent", %{
      creator: creator,
      workspace: workspace
    } do
      {:ok, agent} =
        CustomAgents.create_custom_agent(
          %{name: "Mine", workspace_id: workspace.id},
          actor: creator
        )

      assert {:ok, _} = CustomAgents.get_custom_agent(agent.id, actor: creator)
    end

    test "private workspace agent (no grant) is hidden from active members", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, agent} =
        CustomAgents.create_custom_agent(
          %{name: "Private", workspace_id: workspace.id},
          actor: creator
        )

      _ = add_active_member(workspace, creator, stranger)

      assert {:error, _} = CustomAgents.get_custom_agent(agent.id, actor: stranger)
    end

    test "workspace :viewer grant lets an active member read the agent", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, agent} =
        CustomAgents.create_custom_agent(
          %{name: "Shared", workspace_id: workspace.id},
          actor: creator
        )

      _ = add_active_member(workspace, creator, stranger)

      _grant =
        grant!(%{
          resource_type: :custom_agent,
          resource_id: agent.id,
          grantee_type: :workspace,
          grantee_id: workspace.id,
          role: :viewer
        })

      assert {:ok, _} = CustomAgents.get_custom_agent(agent.id, actor: stranger)
    end

    test "stranger (non-member) cannot see agent even with workspace grant", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, agent} =
        CustomAgents.create_custom_agent(
          %{name: "Granted", workspace_id: workspace.id},
          actor: creator
        )

      _grant =
        grant!(%{
          resource_type: :custom_agent,
          resource_id: agent.id,
          grantee_type: :workspace,
          grantee_id: workspace.id,
          role: :viewer
        })

      assert {:error, _} = CustomAgents.get_custom_agent(agent.id, actor: stranger)
    end

    test "direct user grant lets the grantee read the agent", %{
      creator: creator,
      stranger: stranger,
      workspace: workspace
    } do
      {:ok, agent} =
        CustomAgents.create_custom_agent(
          %{name: "User Shared", workspace_id: workspace.id},
          actor: creator
        )

      # Stranger is not a workspace member; a direct-user grant should still let
      # them read the agent.
      _grant =
        grant!(%{
          resource_type: :custom_agent,
          resource_id: agent.id,
          grantee_type: :user,
          grantee_id: stranger.id,
          role: :viewer
        })

      assert {:ok, _} = CustomAgents.get_custom_agent(agent.id, actor: stranger)
    end
  end

  describe ":my_agents includes personal and grant-accessible agents" do
    setup do
      creator = generate(user())
      other = generate(user())
      ensure_workspace_plan(creator)

      {:ok, workspace} =
        Workspaces.create_workspace(
          %{name: "T", slug: "t-agent-my-#{System.unique_integer([:positive])}"},
          actor: creator
        )

      _ = add_active_member(workspace, creator, other)

      %{creator: creator, other: other, workspace: workspace}
    end

    test "returns the actor's personal agents", %{other: other} do
      {:ok, personal} =
        CustomAgents.create_custom_agent(%{name: "Personal"}, actor: other)

      {:ok, agents} = CustomAgents.list_my_agents(actor: other)
      ids = Enum.map(agents, & &1.id)

      assert personal.id in ids
    end

    test "includes agents the actor has a direct-user grant on", %{
      creator: creator,
      other: other,
      workspace: workspace
    } do
      {:ok, shared} =
        CustomAgents.create_custom_agent(
          %{name: "Shared", workspace_id: workspace.id},
          actor: creator
        )

      _ =
        grant!(%{
          resource_type: :custom_agent,
          resource_id: shared.id,
          grantee_type: :user,
          grantee_id: other.id,
          role: :viewer
        })

      {:ok, agents} = CustomAgents.list_my_agents(actor: other)
      ids = Enum.map(agents, & &1.id)

      assert shared.id in ids
    end

    test "includes agents visible via a workspace-level grant", %{
      creator: creator,
      other: other,
      workspace: workspace
    } do
      {:ok, shared} =
        CustomAgents.create_custom_agent(
          %{name: "Workspace Shared", workspace_id: workspace.id},
          actor: creator
        )

      _ =
        grant!(%{
          resource_type: :custom_agent,
          resource_id: shared.id,
          grantee_type: :workspace,
          grantee_id: workspace.id,
          role: :viewer
        })

      {:ok, agents} = CustomAgents.list_my_agents(actor: other)
      ids = Enum.map(agents, & &1.id)

      assert shared.id in ids
    end

    test "excludes private workspace agents without any grant", %{
      creator: creator,
      other: other,
      workspace: workspace
    } do
      {:ok, private} =
        CustomAgents.create_custom_agent(
          %{name: "Private", workspace_id: workspace.id},
          actor: creator
        )

      {:ok, agents} = CustomAgents.list_my_agents(actor: other)
      ids = Enum.map(agents, & &1.id)

      refute private.id in ids
    end
  end

  describe "share_to_team / unshare_from_team grant sync" do
    setup do
      creator = generate(user())
      member_user = generate(user())
      ensure_workspace_plan(creator)

      {:ok, workspace} =
        Workspaces.create_workspace(
          %{name: "T", slug: "t-ashare-#{System.unique_integer([:positive])}"},
          actor: creator
        )

      _ = add_active_member(workspace, creator, member_user)

      {:ok, agent} =
        CustomAgents.create_custom_agent(
          %{name: "For Sharing", workspace_id: workspace.id},
          actor: creator
        )

      %{
        creator: creator,
        member_user: member_user,
        workspace: workspace,
        agent: agent
      }
    end

    test "share_to_team creates a workspace-level grant", %{
      creator: creator,
      workspace: workspace,
      agent: agent
    } do
      assert grants_for(agent) == []

      {:ok, _shared} = CustomAgents.share_custom_agent_to_team(agent, actor: creator)

      grants = grants_for(agent)
      assert length(grants) == 1

      [g] = grants
      assert g.resource_type == :custom_agent
      assert g.resource_id == agent.id
      assert g.grantee_type == :workspace
      assert g.grantee_id == workspace.id
      assert g.role == :viewer
    end

    test "share_to_team is idempotent when run twice", %{
      creator: creator,
      agent: agent
    } do
      {:ok, _} = CustomAgents.share_custom_agent_to_team(agent, actor: creator)
      {:ok, _} = CustomAgents.share_custom_agent_to_team(agent, actor: creator)

      assert length(grants_for(agent)) == 1
    end

    test "shared agent is readable by active workspace member via grant", %{
      creator: creator,
      member_user: member_user,
      agent: agent
    } do
      # Not readable before sharing.
      assert {:error, _} = CustomAgents.get_custom_agent(agent.id, actor: member_user)

      {:ok, _} = CustomAgents.share_custom_agent_to_team(agent, actor: creator)

      assert {:ok, _} = CustomAgents.get_custom_agent(agent.id, actor: member_user)
    end

    test "unshare_from_team removes the workspace grant", %{
      creator: creator,
      member_user: member_user,
      agent: agent
    } do
      {:ok, _} = CustomAgents.share_custom_agent_to_team(agent, actor: creator)
      assert length(grants_for(agent)) == 1
      assert {:ok, _} = CustomAgents.get_custom_agent(agent.id, actor: member_user)

      {:ok, _} = CustomAgents.unshare_custom_agent_from_team(agent, actor: creator)

      assert grants_for(agent) == []
      assert {:error, _} = CustomAgents.get_custom_agent(agent.id, actor: member_user)
    end
  end

  describe "workspace default agent" do
    setup do
      creator = generate(user())
      member = generate(user())
      ensure_workspace_plan(creator)

      {:ok, workspace} =
        Workspaces.create_workspace(
          %{name: "T", slug: "t-default-#{System.unique_integer([:positive])}"},
          actor: creator
        )

      _ = add_active_member(workspace, creator, member)

      workspace = Ash.load!(workspace, [:default_agent], actor: creator)

      %{creator: creator, member: member, workspace: workspace}
    end

    test "is auto-created on workspace creation and assigned to default_agent_id",
         %{workspace: workspace} do
      assert %Magus.Agents.CustomAgent{} = workspace.default_agent
      assert workspace.default_agent.workspace_id == workspace.id
      assert workspace.default_agent.name == "Workspace Assistant"
      assert workspace.default_agent.handle == "workspace-assistant"
      refute workspace.default_agent.is_default
    end

    test "two workspaces under the same user can share the same handle",
         %{creator: creator, workspace: workspace} do
      {:ok, ws_other} =
        Workspaces.create_workspace(
          %{name: "Other", slug: "other-#{System.unique_integer([:positive])}"},
          actor: creator
        )

      ws_other = Ash.load!(ws_other, [:default_agent], actor: creator)

      assert workspace.default_agent.handle == "workspace-assistant"
      assert ws_other.default_agent.handle == "workspace-assistant"
      refute workspace.default_agent.id == ws_other.default_agent.id
    end

    test "is shared with the workspace via a :viewer ResourceAccess grant",
         %{workspace: workspace} do
      grants = grants_for(workspace.default_agent)
      assert [grant] = grants
      assert grant.grantee_type == :workspace
      assert grant.grantee_id == workspace.id
      assert grant.role == :viewer
    end

    test "is readable by other active workspace members",
         %{workspace: workspace, member: member} do
      assert {:ok, _agent} =
               CustomAgents.get_custom_agent(workspace.default_agent.id, actor: member)
    end

    test "is_shared_to_workspace calculation returns true for the default agent",
         %{workspace: workspace, creator: creator} do
      agent = Ash.load!(workspace.default_agent, [:is_shared_to_workspace], actor: creator)
      assert agent.is_shared_to_workspace == true
    end
  end

  describe "destroy grant cleanup" do
    test "destroying an agent cleans up its ResourceAccess grants" do
      creator = generate(user())
      ensure_workspace_plan(creator)

      {:ok, workspace} =
        Workspaces.create_workspace(
          %{name: "T", slug: "t-adestroy-#{System.unique_integer([:positive])}"},
          actor: creator
        )

      {:ok, agent} =
        CustomAgents.create_custom_agent(
          %{name: "To Destroy", workspace_id: workspace.id},
          actor: creator
        )

      {:ok, _} = CustomAgents.share_custom_agent_to_team(agent, actor: creator)
      assert length(grants_for(agent)) == 1

      :ok = CustomAgents.destroy_custom_agent(agent, actor: creator)

      assert grants_for(agent) == []
    end
  end
end
