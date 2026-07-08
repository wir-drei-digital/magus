defmodule Magus.Agents do
  @moduledoc """
  Ash domain for agent-related resources.

  Manages agent state persistence, lifecycle, and custom agent configuration.
  """

  use Ash.Domain, otp_app: :magus, extensions: [AshTypescript.Rpc]

  typescript_rpc do
    resource Magus.Agents.CustomAgent do
      # @mention autocomplete in the SPA composer (mirrors
      # MagusWeb.Workbench.Chat.Helpers.load_available_agents/1).
      rpc_action :my_agents, :my_agents
      rpc_action :merged_slash_commands, :merged_slash_commands

      # Agents mode (migration iteration 6): list, config sections
      # (general/tools/privacy/automation via :update), share, run-now.
      rpc_action :workspace_agents, :workspace_agents
      rpc_action :create_custom_agent, :create
      rpc_action :update_custom_agent, :update
      rpc_action :destroy_custom_agent, :destroy
      rpc_action :share_agent_to_team, :share_to_team
      rpc_action :unshare_agent_from_team, :unshare_from_team
      rpc_action :trigger_agent_run, :trigger_run
      rpc_action :list_available_skills, :available_skills
      rpc_action :agent_memories, :agent_memories
      rpc_action :update_agent_memory, :update_agent_memory
      rpc_action :delete_agent_memory, :delete_agent_memory
      rpc_action :agent_knowledge_access, :agent_knowledge_access
      rpc_action :set_agent_resource_access, :set_agent_resource_access
      rpc_action :agent_attachments, :agent_attachments
      rpc_action :add_agent_attachment, :add_agent_attachment
      rpc_action :set_agent_attachment_mode, :set_agent_attachment_mode
      rpc_action :remove_agent_attachment, :remove_agent_attachment
      rpc_action :agent_integrations, :agent_integrations
      rpc_action :disconnect_agent_integration, :disconnect_agent_integration
      rpc_action :set_agent_integration_tool, :set_agent_integration_tool
      rpc_action :available_integration_providers, :available_integration_providers
      rpc_action :connect_agent_integration, :connect_agent_integration

      rpc_action :get_custom_agent, :read do
        get_by [:id]
      end
    end

    resource Magus.Agents.AgentActivityLog do
      rpc_action :agent_activity, :for_agent
    end

    resource Magus.Agents.AgentInboxEvent do
      rpc_action :agent_inbox_events, :for_agent
      rpc_action :dismiss_inbox_event, :dismiss
    end

    # Secret VALUES are deliberately never selected by the SPA (write-only
    # from its perspective); the owner-only read policy still gates the field
    # for any client that asks.
    resource Magus.Agents.AgentSecret do
      rpc_action :agent_secrets, :for_agent
      rpc_action :create_agent_secret, :create
      rpc_action :update_agent_secret, :update
      rpc_action :destroy_agent_secret, :destroy
    end
  end

  resources do
    resource Magus.Agents.CustomAgent do
      define :create_custom_agent, action: :create
      define :update_custom_agent, action: :update
      define :destroy_custom_agent, action: :destroy
      define :get_custom_agent, action: :read, get_by: [:id]
      define :get_custom_agent_by_handle, action: :get_by_handle, args: [:handle]
      define :list_my_agents, action: :my_agents
      define :list_personal_agents, action: :personal_agents
      define :list_workspace_agents, action: :workspace_agents, args: [:workspace_id]
      define :get_default_agent, action: :get_default
      define :create_default_agent, action: :create_default
      define :create_workspace_default_agent, action: :create_workspace_default
      define :increment_agent_use_count, action: :increment_use_count
      define :share_custom_agent_to_team, action: :share_to_team
      define :unshare_custom_agent_from_team, action: :unshare_from_team

      define :set_custom_agent_next_scheduled_at,
        action: :set_next_scheduled_at,
        args: [:next_scheduled_at]

      define :pause_custom_agent_for_failures,
        action: :pause_for_failures,
        args: [:pause_reason]
    end

    resource Magus.Agents.AgentSecret do
      define :create_agent_secret, action: :create
      define :get_agent_secret, action: :read, get_by: [:id]
      define :list_agent_secrets, action: :for_agent, args: [:custom_agent_id]
      define :sandbox_env_for_agent, action: :sandbox_env_for_agent, args: [:custom_agent_id]
      define :update_agent_secret, action: :update
      define :destroy_agent_secret, action: :destroy
    end

    resource Magus.Agents.AgentState do
      define :get_agent_state_by_key,
        action: :by_key,
        args: [:agent_module, :agent_id]

      define :upsert_agent_state,
        action: :upsert

      define :delete_agent_state,
        action: :destroy
    end

    resource Magus.Agents.AgentInboxEvent do
      define :create_inbox_event, action: :create
      define :create_waiting_inbox_event, action: :create_waiting
      define :start_processing_event, action: :start_processing
      define :resolve_event, action: :resolve
      define :dismiss_event, action: :dismiss
      define :dismiss_event_by_agent, action: :dismiss_by_agent
      define :mark_event_waiting, action: :mark_waiting
      define :expire_event, action: :expire
      define :list_pending_events, action: :pending_for_agent, args: [:agent_id]
      define :list_agent_events, action: :for_agent, args: [:agent_id]
      define :get_event_by_idempotency_key, action: :by_idempotency_key, args: [:idempotency_key]

      define :get_waiting_approval,
        action: :waiting_approval_for_conversation,
        args: [:conversation_id]

      define :link_event_to_run, action: :link_to_run, args: [:run_id]
      define :unlink_event_from_run, action: :unlink_from_run
      define :resolve_event_via_run, action: :resolve_via_run
    end

    resource Magus.Agents.AgentActivityLog do
      define :create_activity_log, action: :create
      define :list_agent_activity, action: :for_agent, args: [:agent_id]
      define :list_user_activity, action: :for_user
    end

    resource Magus.Agents.CustomAgentAttachment do
      define :create_attachment, action: :create
      define :update_attachment, action: :update
      define :destroy_attachment, action: :destroy
      define :list_agent_attachments, action: :for_agent, args: [:custom_agent_id]
    end

    resource Magus.Agents.AgentRun do
      define :get_agent_run, action: :read, get_by: [:id]
      define :create_agent_run, action: :create
      define :start_agent_run, action: :start
      define :heartbeat_agent_run, action: :heartbeat
      define :complete_agent_run, action: :complete
      define :fail_agent_run, action: :fail
      define :exceed_budget_agent_run, action: :exceed_budget
      define :timeout_agent_run, action: :timeout
      define :cancel_agent_run, action: :cancel
      define :requeue_agent_run, action: :requeue
      define :mark_delivered_agent_run, action: :mark_delivered

      define :running_agent_runs,
        action: :running_for_source,
        args: [:source_conversation_id]

      define :running_agent_runs_by_target,
        action: :running_for_target,
        args: [:target_conversation_id]
    end
  end

  @doc """
  Returns sandbox_env secrets for the given agent as a plain string map
  suitable for injecting as environment variables.

  Returns `{:ok, %{"KEY" => "value"}}` or `{:error, reason}`.
  """
  def sandbox_env_map_for_agent(custom_agent_id, opts \\ []) do
    secrets_result =
      case Keyword.get(opts, :actor) do
        %Magus.Agents.Support.AiAgent{} ->
          list_sandbox_env_for_agent_internal(custom_agent_id, opts)

        _ ->
          sandbox_env_for_agent(custom_agent_id, opts)
      end

    case secrets_result do
      {:ok, secrets} ->
        env_map = Map.new(secrets, fn s -> {s.key, s.value} end)
        {:ok, env_map}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_sandbox_env_for_agent_internal(custom_agent_id, opts) do
    Magus.Agents.AgentSecret
    |> Ash.Query.for_read(:sandbox_env_for_agent, %{custom_agent_id: custom_agent_id})
    |> Ash.read(Keyword.merge(opts, authorize?: false))
  end

  @doc """
  Gets or creates the default agent for a user.

  This is the lazy-creation pattern for existing users who don't have
  a default agent yet. Returns `{:ok, agent}` or `{:error, reason}`.
  """
  def ensure_default_agent(user) do
    case get_default_agent(actor: user) do
      {:ok, agent} ->
        {:ok, agent}

      {:error, %Ash.Error.Query.NotFound{}} ->
        create_default_agent_for_user(user)

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        if Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) do
          create_default_agent_for_user(user)
        else
          {:error, errors}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_default_agent_for_user(user) do
    create_default_agent(
      %{name: "Personal Assistant"},
      actor: user
    )
  end

  @doc """
  Returns the workspace's shared default agent, lazily provisioning one if the
  workspace has no `default_agent_id` set (e.g. legacy workspace, or the
  previous default agent was deleted).

  Mirrors `ensure_default_agent/1` but for workspace scope. Use this on the
  hot path when creating workspace conversations to enforce strict workspace
  separation.

  Returns `{:ok, agent}` or `{:error, reason}`.
  """
  def ensure_workspace_default_agent(%Magus.Workspaces.Workspace{} = workspace, actor) do
    workspace = Ash.load!(workspace, [:default_agent], actor: actor)

    case workspace.default_agent do
      nil -> provision_workspace_default_agent(workspace, actor)
      agent -> {:ok, agent}
    end
  end

  def ensure_workspace_default_agent(workspace_id, actor) when is_binary(workspace_id) do
    case Magus.Workspaces.get_workspace(workspace_id, actor: actor) do
      {:ok, workspace} -> ensure_workspace_default_agent(workspace, actor)
      {:error, reason} -> {:error, reason}
    end
  end

  defp provision_workspace_default_agent(workspace, actor) do
    with {:ok, agent} <-
           create_workspace_default_agent(
             %{name: "Workspace Assistant", workspace_id: workspace.id},
             actor: actor,
             authorize?: false
           ),
         {:ok, _grant} <-
           Magus.Workspaces.grant_access(
             %{
               resource_type: :custom_agent,
               resource_id: agent.id,
               grantee_type: :workspace,
               grantee_id: workspace.id,
               role: :viewer
             },
             authorize?: false
           ),
         {:ok, _updated} <-
           workspace
           |> Ash.Changeset.for_update(:update, %{default_agent_id: agent.id})
           |> Ash.update(authorize?: false) do
      {:ok, agent}
    end
  end
end
