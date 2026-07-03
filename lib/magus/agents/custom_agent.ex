defmodule Magus.Agents.CustomAgent do
  @moduledoc """
  A user-created custom AI agent with persistent configuration.

  Custom Agents bundle instructions, model selection, tool scoping,
  skill pre-loading, and conversation starters into a reusable persona.

  Each user has one default agent (is_default: true) that powers regular
  conversations. Additional agents can be created for specialized tasks.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub],
    extensions: [AshTypescript.Resource, AshOban]

  postgres do
    table "custom_agents"
    repo Magus.Repo

    identity_wheres_to_sql unique_default: "is_default = true",
                           unique_handle_per_workspace: "workspace_id IS NOT NULL",
                           unique_handle_personal: "workspace_id IS NULL"

    base_filter_sql "deleted_at IS NULL"
  end

  resource do
    base_filter expr(is_nil(deleted_at))
  end

  typescript do
    type_name "CustomAgent"
  end

  oban do
    triggers do
      trigger :watchdog_reset_overdue_schedules do
        action :watchdog_reset_schedule
        queue :agent_heartbeat_watchdog
        scheduler_cron "0 * * * *"
        read_action :watchdog_overdue_agents
        worker_read_action :watchdog_overdue_agents
        where expr(is_watchdog_overdue)
        worker_module_name Magus.Agents.CustomAgent.Workers.WatchdogReset
        scheduler_module_name Magus.Agents.CustomAgent.Schedulers.WatchdogReset
        max_attempts 1
      end
    end
  end

  actions do
    destroy :destroy do
      soft? true
      require_atomic? false

      change set_attribute(:deleted_at, &DateTime.utc_now/0)

      validate attribute_does_not_equal(:is_default, true) do
        message "cannot delete the default agent"
      end

      change Magus.Agents.CustomAgent.Changes.CleanupUploadedFiles
      change {Magus.Workspaces.Changes.DestroyResourceGrants, resource_type: :custom_agent}
    end

    read :read do
      primary? true
    end

    read :my_agents do
      prepare Magus.Agents.CustomAgent.Preparations.MyAgentsAccess
      prepare build(sort: [is_default: :desc, updated_at: :desc])
    end

    read :personal_agents do
      description "User-owned agents with no workspace_id."
      filter expr(user_id == ^actor(:id) and is_nil(workspace_id))
      prepare build(sort: [is_default: :desc, updated_at: :desc])
    end

    read :workspace_agents do
      description "List agents scoped to a workspace (read authorization governed by policies)"
      argument :workspace_id, :uuid, allow_nil?: false
      filter expr(workspace_id == ^arg(:workspace_id))

      prepare build(
                load: [:is_shared_to_workspace],
                sort: [is_default: :desc, updated_at: :desc]
              )
    end

    read :get_by_handle do
      description "Look up a custom agent by handle for the current user"
      argument :handle, :string, allow_nil?: false
      get? true
      filter expr(user_id == ^actor(:id) and handle == ^arg(:handle))
    end

    read :get_default do
      get? true
      filter expr(user_id == ^actor(:id) and is_default == true)
    end

    read :watchdog_overdue_agents do
      description """
      Heartbeat-enabled, unpaused agents whose next_scheduled_at is more than
      2x their heartbeat_default_interval_minutes in the past. Backs the
      hourly watchdog trigger that self-heals a lost schedule advance.
      """

      pagination keyset?: true, required?: false
      filter expr(is_watchdog_overdue)
    end

    create :create do
      accept [
        :name,
        :description,
        :icon,
        :image_path,
        :instructions,
        :slash_commands,
        :chat_mode,
        :disabled_tool_categories,
        :pre_loaded_skills,
        :sampling_settings,
        :max_iterations,
        :can_read_global_memories,
        :can_write_global_memories,
        :can_access_global_files,
        :can_access_knowledge,
        :model_id,
        :image_model_id,
        :video_model_id,
        :workspace_id,
        :is_paused,
        :max_daily_runs,
        :max_tokens_per_run,
        :heartbeat_enabled,
        :heartbeat_instructions,
        :heartbeat_default_interval_minutes,
        :next_scheduled_at
      ]

      change relate_actor(:user)
      change Magus.Agents.CustomAgent.Changes.GenerateHandle
      validate Magus.Agents.CustomAgent.Validations.HandleFormat
    end

    create :create_default do
      accept [:name]
      change set_attribute(:is_default, true)
      change relate_actor(:user)
      change Magus.Agents.CustomAgent.Changes.GenerateHandle
    end

    create :create_workspace_default do
      description "Auto-created default agent owned by a workspace; visible to all members."
      accept [:name, :workspace_id]
      change relate_actor(:user)
      change Magus.Agents.CustomAgent.Changes.GenerateHandle
    end

    update :update do
      primary? true
      require_atomic? false
      validate Magus.Agents.CustomAgent.Validations.HandleFormat

      accept [
        :name,
        :handle,
        :description,
        :icon,
        :image_path,
        :instructions,
        :slash_commands,
        :chat_mode,
        :disabled_tool_categories,
        :pre_loaded_skills,
        :sampling_settings,
        :max_iterations,
        :can_read_global_memories,
        :can_write_global_memories,
        :can_access_global_files,
        :can_access_knowledge,
        :model_id,
        :image_model_id,
        :video_model_id,
        :is_paused,
        :max_daily_runs,
        :max_tokens_per_run,
        :heartbeat_enabled,
        :heartbeat_instructions,
        :heartbeat_default_interval_minutes,
        :next_scheduled_at
      ]

      # Resuming an agent (flipping is_paused to false, e.g. via the SPA kill
      # switch) should clear any auto-pause reason so a stale escalation
      # banner doesn't linger after the user has manually resumed it.
      change fn changeset, _context ->
        if Ash.Changeset.get_attribute(changeset, :is_paused) == false do
          Ash.Changeset.force_change_attribute(changeset, :pause_reason, nil)
        else
          changeset
        end
      end
    end

    update :pause_for_failures do
      description """
      Auto-pause triggered by FailureStreak after 10 consecutive failed
      autonomous runs. Idempotent: a no-op change set if the agent is
      already paused.
      """

      accept []
      require_atomic? false

      argument :pause_reason, :string, allow_nil?: false

      change set_attribute(:is_paused, true)
      change set_attribute(:pause_reason, arg(:pause_reason))
    end

    update :set_next_scheduled_at do
      accept [:next_scheduled_at]
    end

    update :clear_next_scheduled_at do
      change set_attribute(:next_scheduled_at, nil)
    end

    update :watchdog_reset_schedule do
      description "Oban-triggered self-heal for an overdue heartbeat schedule"
      accept []
      require_atomic? false
      transaction? false

      change Magus.Agents.CustomAgent.Changes.WatchdogReset
    end

    update :increment_use_count do
      change atomic_update(:use_count, expr(use_count + 1))
    end

    update :share_to_team do
      accept []
      require_atomic? false
      validate present(:workspace_id), message: "custom agent must belong to a workspace"

      change {Magus.Workspaces.Changes.GrantWorkspaceAccess, resource_type: :custom_agent}
    end

    update :unshare_from_team do
      accept []
      require_atomic? false
      validate present(:workspace_id), message: "custom agent must belong to a workspace"

      change {Magus.Workspaces.Changes.RevokeWorkspaceAccess, resource_type: :custom_agent}
    end

    action :merged_slash_commands, {:array, :map} do
      description """
      Composer plus-menu: globals merged with the agent's own commands
      (agent commands override globals by name). Titles are pre-localized.
      """

      argument :agent_id, :uuid, allow_nil?: true

      run fn input, context ->
        agent_commands =
          case input.arguments.agent_id do
            nil ->
              []

            id ->
              case Ash.get(__MODULE__, id, actor: context.actor) do
                {:ok, agent} -> agent.slash_commands || []
                _ -> []
              end
          end

        commands =
          agent_commands
          |> Magus.Agents.SlashCommands.merge()
          |> Enum.map(fn command ->
            %{
              name: to_string(command.name),
              title: Magus.Agents.SlashCommands.title(command.title),
              icon: command[:icon]
            }
          end)

        {:ok, commands}
      end
    end

    action :available_skills, {:array, :map} do
      description """
      Skills registry list for the agent editor's pre-loaded-skills picker:
      name + description for every loaded skill.
      """

      run fn _input, _context ->
        skills =
          Magus.Agents.Skills.Registry.list_skills()
          |> Enum.map(fn skill ->
            %{name: skill.name, description: skill.description || ""}
          end)
          |> Enum.sort_by(& &1.name)

        {:ok, skills}
      end
    end

    # --- Knowledge section (agent editor): memories + brain/collection grants. ---
    # Thin wrappers over the existing Memory / Workspaces / Brain / Knowledge
    # contexts; each underlying call enforces its own policy via actor:.

    action :agent_memories, {:array, :map} do
      description "Memories scoped to an agent, for the editor's Knowledge section."
      argument :agent_id, :uuid, allow_nil?: false

      run fn input, context ->
        case Magus.Memory.list_agent_memories(input.arguments.agent_id, actor: context.actor) do
          {:ok, memories} -> {:ok, Enum.map(memories, &memory_map/1)}
          {:error, error} -> {:error, error}
        end
      end
    end

    action :update_agent_memory, :map do
      description "Edit an agent memory's summary / kind / confidence."
      argument :memory_id, :uuid, allow_nil?: false
      argument :summary, :string, allow_nil?: true
      argument :kind, :string, allow_nil?: false
      argument :confidence, :float, allow_nil?: false

      run fn input, context ->
        with {:ok, memory} <-
               Magus.Memory.get_memory(input.arguments.memory_id, actor: context.actor),
             attrs = %{
               summary: input.arguments.summary,
               kind: safe_memory_kind(input.arguments.kind),
               confidence: clamp_confidence(input.arguments.confidence)
             },
             {:ok, updated} <-
               Magus.Memory.set_memory(memory, memory.content || %{}, attrs, actor: context.actor) do
          {:ok, memory_map(updated)}
        end
      end
    end

    action :delete_agent_memory, :map do
      description "Deactivate (delete) an agent memory."
      argument :memory_id, :uuid, allow_nil?: false

      run fn input, context ->
        with {:ok, memory} <-
               Magus.Memory.get_memory(input.arguments.memory_id, actor: context.actor),
             {:ok, _} <- Magus.Memory.deactivate_memory(memory, actor: context.actor) do
          {:ok, %{id: input.arguments.memory_id}}
        end
      end
    end

    action :agent_knowledge_access, :map do
      description "Brains + knowledge collections with this agent's grant flags."
      argument :agent_id, :uuid, allow_nil?: false

      run fn input, context ->
        user = context.actor
        agent_id = input.arguments.agent_id

        brains =
          Magus.Brain.list_brains!(actor: user)
          |> Enum.map(fn brain ->
            %{
              id: brain.id,
              title: brain.title,
              icon: brain.icon,
              granted: agent_resource_granted?(:brain, brain.id, agent_id, user)
            }
          end)

        sources =
          case Magus.Knowledge.list_sources_for_user(actor: user) do
            {:ok, list} -> list
            _ -> []
          end

        source_groups =
          sources
          |> Enum.map(fn source ->
            collections =
              case Magus.Knowledge.list_collections_for_source(source.id, actor: user) do
                {:ok, list} -> list
                _ -> []
              end

            %{
              name: source.name,
              collections:
                Enum.map(collections, fn collection ->
                  %{
                    id: collection.id,
                    name: collection.name,
                    item_count: collection.item_count || 0,
                    granted:
                      agent_resource_granted?(
                        :knowledge_collection,
                        collection.id,
                        agent_id,
                        user
                      )
                  }
                end)
            }
          end)
          |> Enum.reject(&(&1.collections == []))

        {:ok, %{brains: brains, sources: source_groups}}
      end
    end

    action :set_agent_resource_access, :map do
      description "Grant or revoke an agent's access to a brain / knowledge collection."
      argument :agent_id, :uuid, allow_nil?: false
      argument :resource_type, :string, allow_nil?: false
      argument :resource_id, :uuid, allow_nil?: false
      argument :granted, :boolean, allow_nil?: false

      run fn input, context ->
        user = context.actor
        agent_id = input.arguments.agent_id
        resource_id = input.arguments.resource_id

        with :ok <- assert_agent_editable(agent_id, user),
             resource_type when not is_nil(resource_type) <-
               resource_type_atom(input.arguments.resource_type) do
          if input.arguments.granted do
            case Magus.Workspaces.grant_access(
                   %{
                     resource_type: resource_type,
                     resource_id: resource_id,
                     grantee_type: :custom_agent,
                     grantee_id: agent_id,
                     role: :editor
                   },
                   actor: user
                 ) do
              {:ok, _} -> {:ok, %{granted: true}}
              {:error, error} -> {:error, error}
            end
          else
            with {:ok, grants} <-
                   Magus.Workspaces.list_access_for_resource(resource_type, resource_id,
                     actor: user
                   ),
                 grant when not is_nil(grant) <-
                   Enum.find(
                     grants,
                     &(&1.grantee_type == :custom_agent && &1.grantee_id == agent_id)
                   ) do
              case Magus.Workspaces.revoke_access(grant, actor: user) do
                {:ok, _} -> {:ok, %{granted: false}}
                :ok -> {:ok, %{granted: false}}
                {:error, error} -> {:error, error}
              end
            else
              _ -> {:ok, %{granted: false}}
            end
          end
        else
          {:error, _} = error -> error
          nil -> {:error, "not authorized or invalid resource_type"}
        end
      end
    end

    # --- Attachments section: agent reference files (always / search mode). ---

    action :agent_attachments, {:array, :map} do
      description "Files attached to an agent (always-include / search), for the editor."
      argument :agent_id, :uuid, allow_nil?: false

      run fn input, context ->
        # CustomAgentAttachment has no authorizer of its own; gate the list on
        # the actor being able to read the owning agent.
        with {:ok, _agent} <-
               Magus.Agents.get_custom_agent(input.arguments.agent_id, actor: context.actor),
             {:ok, attachments} <-
               Magus.Agents.list_agent_attachments(input.arguments.agent_id,
                 actor: context.actor,
                 load: [file: [:chunks]]
               ) do
          {:ok, Enum.map(attachments, &attachment_map/1)}
        end
      end
    end

    action :add_agent_attachment, :map do
      description "Attach an existing file to an agent."
      argument :agent_id, :uuid, allow_nil?: false
      argument :file_id, :uuid, allow_nil?: false
      argument :mode, :string, allow_nil?: false

      run fn input, context ->
        # Both the agent (editable by actor) AND the file (readable by actor)
        # must be authorized: create_attachment grants the agent :viewer on the
        # file with authorize?: false, so without this the file_id would be an
        # unchecked cross-tenant read vector.
        with :ok <- assert_agent_editable(input.arguments.agent_id, context.actor),
             {:ok, _file} <- Magus.Files.get_file(input.arguments.file_id, actor: context.actor),
             {:ok, attachment} <-
               Magus.Agents.create_attachment(
                 %{
                   custom_agent_id: input.arguments.agent_id,
                   file_id: input.arguments.file_id,
                   mode: safe_attachment_mode(input.arguments.mode),
                   position: 0
                 },
                 actor: context.actor
               ) do
          {:ok, %{id: attachment.id}}
        end
      end
    end

    action :set_agent_attachment_mode, :map do
      description "Switch an attachment between always-include and search mode."
      argument :attachment_id, :uuid, allow_nil?: false
      argument :mode, :string, allow_nil?: false

      run fn input, context ->
        with {:ok, attachment} <-
               Ash.get(Magus.Agents.CustomAgentAttachment, input.arguments.attachment_id,
                 actor: context.actor
               ),
             :ok <- assert_agent_editable(attachment.custom_agent_id, context.actor),
             {:ok, updated} <-
               Magus.Agents.update_attachment(
                 attachment,
                 %{mode: safe_attachment_mode(input.arguments.mode)},
                 actor: context.actor
               ) do
          {:ok, %{id: updated.id, mode: to_string(updated.mode)}}
        end
      end
    end

    action :remove_agent_attachment, :map do
      description "Detach a file from an agent."
      argument :attachment_id, :uuid, allow_nil?: false

      run fn input, context ->
        with {:ok, attachment} <-
               Ash.get(Magus.Agents.CustomAgentAttachment, input.arguments.attachment_id,
                 actor: context.actor
               ),
             :ok <- assert_agent_editable(attachment.custom_agent_id, context.actor),
             :ok <- Magus.Agents.destroy_attachment(attachment, actor: context.actor) do
          {:ok, %{id: input.arguments.attachment_id}}
        end
      end
    end

    # --- Integrations section (manage-only): list / disconnect / tool toggle. ---
    # UserIntegration has owner-only policies (relates_to_actor_via :user), so the
    # underlying calls enforce ownership via actor:. The connect-wizard (OAuth /
    # credentials) is intentionally not exposed here.

    action :agent_integrations, {:array, :map} do
      description "Connected integrations for an agent (list / manage)."
      argument :agent_id, :uuid, allow_nil?: false

      run fn input, context ->
        with {:ok, _agent} <-
               Magus.Agents.get_custom_agent(input.arguments.agent_id, actor: context.actor),
             {:ok, integrations} <-
               Magus.Integrations.list_agent_integrations(input.arguments.agent_id,
                 actor: context.actor
               ) do
          meta =
            Magus.Integrations.list_available_providers() |> Map.new(&{&1.key, &1})

          {:ok, Enum.map(integrations, &integration_map(&1, meta))}
        end
      end
    end

    action :disconnect_agent_integration, :map do
      description "Disconnect (revoke credential + delete) an agent integration."
      argument :integration_id, :uuid, allow_nil?: false

      run fn input, context ->
        # Owner-only read enforces ownership before the credential cleanup.
        with {:ok, integration} <-
               Ash.get(Magus.Integrations.UserIntegration, input.arguments.integration_id,
                 actor: context.actor
               ) do
          disconnect_integration(integration, context.actor)
          {:ok, %{id: input.arguments.integration_id}}
        end
      end
    end

    action :set_agent_integration_tool, :map do
      description "Enable or disable a tool exposed by an integration."
      argument :integration_id, :uuid, allow_nil?: false
      argument :tool, :string, allow_nil?: false
      argument :enabled, :boolean, allow_nil?: false

      run fn input, context ->
        with {:ok, integration} <-
               Ash.get(Magus.Integrations.UserIntegration, input.arguments.integration_id,
                 actor: context.actor
               ),
             {:ok, tool} <- safe_tool_atom(input.arguments.tool) do
          enabled_tools = integration.enabled_tools || []

          new_tools =
            if input.arguments.enabled,
              do: Enum.uniq([tool | enabled_tools]),
              else: List.delete(enabled_tools, tool)

          case Magus.Integrations.update_integration_enabled_tools(
                 integration,
                 %{enabled_tools: new_tools},
                 actor: context.actor
               ) do
            {:ok, updated} ->
              {:ok,
               %{
                 id: updated.id,
                 enabled_tools: Enum.map(updated.enabled_tools || [], &to_string/1)
               }}

            {:error, error} ->
              {:error, error}
          end
        else
          :error -> {:error, "unknown tool"}
          other -> other
        end
      end
    end

    action :available_integration_providers, {:array, :map} do
      description "Connectable integration providers for the agent connect wizard."
      argument :agent_id, :uuid, allow_nil?: false

      run fn input, context ->
        with {:ok, _agent} <-
               Magus.Agents.get_custom_agent(input.arguments.agent_id, actor: context.actor) do
          {:ok, connectable_providers(context.actor)}
        end
      end
    end

    action :connect_agent_integration, :map do
      description "Connect a new integration for an agent (runs the SetupIntegration reactor)."
      argument :agent_id, :uuid, allow_nil?: false
      argument :provider_key, :string, allow_nil?: false
      argument :credentials, :map, allow_nil?: true, default: %{}
      argument :config, :map, allow_nil?: true, default: %{}

      run fn input, context ->
        with :ok <- assert_agent_editable(input.arguments.agent_id, context.actor) do
          connect_agent_integration(
            input.arguments.agent_id,
            input.arguments.provider_key,
            input.arguments[:credentials] || %{},
            input.arguments[:config] || %{},
            context.actor
          )
        end
      end
    end

    action :trigger_run, :map do
      description """
      Manual wake-up ("Run now") for the SvelteKit workbench. Mirrors the
      classic Automation section: ensures the agent's home conversation,
      enqueues a :manual_trigger run through RunOrchestrator (budget gates
      apply), and drops the heartbeat trace message. Authorization is
      delegated to get_custom_agent/2 inside the run.
      """

      argument :agent_id, :uuid, allow_nil?: false

      run fn input, context ->
        actor = context.actor

        with {:ok, agent} <-
               Magus.Agents.get_custom_agent(input.arguments.agent_id, actor: actor),
             # Read access is not enough: workspace viewers can see shared
             # agents but must not trigger paid runs (classic exposes Run now
             # only in the edit view). Require update capability.
             true <-
               Ash.can?({agent, :update}, actor) ||
                 {:error, "not allowed to trigger runs for this agent"},
             {:ok, home} <- Magus.Agents.Support.HomeConversation.ensure(actor.id, agent.id),
             {:ok, run} <-
               Magus.Agents.RunOrchestrator.enqueue(%{
                 kind: :delegate,
                 source: :manual_trigger,
                 source_conversation_id: home.id,
                 target_conversation_id: home.id,
                 target_agent_id: agent.id,
                 initiator_user_id: actor.id,
                 request_id: "manual-#{Ash.UUID.generate()}",
                 idempotency_key: nil,
                 objective: "Manual wake-up triggered from UI"
               }) do
          user_label = actor.display_name || to_string(actor.email) || "user"

          _ =
            Magus.Agents.HeartbeatEventMessage.create(home.id,
              run_id: run.id,
              source: :manual_trigger,
              user_label: user_label
            )

          {:ok, %{run_id: run.id, home_conversation_id: home.id}}
        end
      end
    end
  end

  policies do
    import Magus.Workspaces.Policies

    # The hourly watchdog trigger reads/updates across all users' agents with
    # no real actor; AshOban authorizes its own calls via this check.
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # Generic action — agent access is checked via get_custom_agent/2 (read
    # policies) inside the run before anything is enqueued.
    policy action(:trigger_run) do
      authorize_if always()
    end

    # Globals + the actor-readable agent's commands; the inner Ash.get is
    # actor-authorized, unknown/foreign agents just fall back to globals.
    policy action(:merged_slash_commands) do
      authorize_if always()
    end

    # Reads only the global skills registry; no per-agent data.
    policy action(:available_skills) do
      authorize_if always()
    end

    # Knowledge-section actions: the action layer just requires an actor; the
    # wrapped Memory / Workspaces / Brain / Knowledge calls each enforce their
    # own ownership policies via actor:.
    policy action([
             :agent_memories,
             :update_agent_memory,
             :delete_agent_memory,
             :agent_knowledge_access,
             :set_agent_resource_access,
             :agent_attachments,
             :add_agent_attachment,
             :set_agent_attachment_mode,
             :remove_agent_attachment,
             :agent_integrations,
             :disconnect_agent_integration,
             :set_agent_integration_tool,
             :available_integration_providers,
             :connect_agent_integration
           ]) do
      authorize_if actor_present()
    end

    # AI agents acting on behalf of users can read their own agent config
    # (used by autonomous tools to fetch the agent struct before scheduling).
    # Read access is low-risk (no mutation possible).
    bypass action_type(:read) do
      authorize_if Magus.Checks.IsAiAgent
    end

    # AI agents may invoke ONLY the narrowly-scoped scheduling actions. The
    # generic :update action remains user-only to prevent prompt-injection
    # induced privilege escalation (e.g. clearing :is_paused, removing
    # :max_daily_runs, swapping :model_id, or rewriting :instructions).
    bypass action([:set_next_scheduled_at, :clear_next_scheduled_at]) do
      authorize_if Magus.Checks.IsAiAgent
    end

    workspace_scoped_policies(resource_type: :custom_agent)
  end

  pub_sub do
    module MagusWeb.Endpoint
    prefix "workspaces"

    # Minimal payload by design: subscribers refetch on receipt rather than render
    # directly from broadcasts, so we intentionally omit sensitive fields like
    # instructions and system prompt content.
    publish_all :create, [:workspace_id, "agents"] do
      filter fn %{data: a} -> not is_nil(a.workspace_id) end
      transform fn %{data: a} -> %{id: a.id, workspace_id: a.workspace_id, action: :created} end
    end

    publish_all :update, [:workspace_id, "agents"] do
      filter fn %{data: a} -> not is_nil(a.workspace_id) end
      transform fn %{data: a} -> %{id: a.id, workspace_id: a.workspace_id, action: :updated} end
    end

    publish_all :destroy, [:workspace_id, "agents"] do
      filter fn %{data: a} -> not is_nil(a.workspace_id) end
      transform fn %{data: a} -> %{id: a.id, workspace_id: a.workspace_id, action: :deleted} end
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Display name of the agent"
    end

    attribute :handle, :string do
      allow_nil? false
      public? true
      description "Unique mention handle (lowercase alphanumeric + hyphens, e.g. 'my-agent')"
      constraints min_length: 1
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      description "What this agent does"
    end

    attribute :icon, :string do
      allow_nil? true
      public? true
      description "Emoji or icon identifier"
    end

    attribute :image_path, :string do
      allow_nil? true
      public? true
      description "Path to AI-generated profile image in storage"
    end

    attribute :instructions, :string do
      allow_nil? true
      public? true
      description "System prompt text — the agent's persona and behavior instructions"
    end

    attribute :slash_commands, {:array, Magus.Agents.SlashCommand} do
      default []
      public? true

      description "Custom slash commands for this agent, shown as conversation starters and in the + menu"
    end

    attribute :chat_mode, :atom do
      constraints one_of: [:chat, :search, :reasoning, :image_generation, :video_generation]
      allow_nil? true
      public? true
      description "Default chat mode preset"
    end

    attribute :disabled_tool_categories, {:array, :atom} do
      default []
      public? true

      constraints items: [
                    one_of: [:web, :code, :memory, :files, :skills, :tasks, :integrations]
                  ]

      description """
      Tool categories to disable for this agent. Empty = all tools available.
      Categories: :web, :code, :memory, :files, :skills, :tasks, :integrations
      """
    end

    attribute :pre_loaded_skills, {:array, :string} do
      default []
      public? true
      description "Skill names from the registry to pre-load for every conversation"
    end

    attribute :sampling_settings, :map do
      allow_nil? true
      public? true
      description "LLM sampling settings: temperature, max_tokens, top_p, top_k"
    end

    attribute :max_iterations, :integer do
      allow_nil? true
      public? true
      constraints min: 1

      description "Maximum agentic loop iterations. nil = use system default (Magus.Config.max_iterations/0)."
    end

    attribute :is_default, :boolean do
      default false
      public? true
      description "Whether this is the user's default agent for regular conversations"
    end

    attribute :is_public, :boolean do
      default false
      public? true
      description "Whether this agent is visible to other users (future)"
    end

    attribute :can_read_global_memories, :boolean do
      default true
      public? true
      description "Whether this agent can access the user's global memories"
    end

    attribute :can_write_global_memories, :boolean do
      default true
      public? true
      description "Whether conversations with this agent can create/modify global memories"
    end

    attribute :can_access_global_files, :boolean do
      default true
      public? true
      description "Whether this agent's RAG search includes the user's global files"
    end

    attribute :can_access_knowledge, :boolean do
      default true
      public? true
      description "Whether this agent can access knowledge collection files"
    end

    attribute :use_count, :integer do
      default 0
      public? false
      description "Number of conversations started with this agent"
    end

    attribute :is_paused, :boolean do
      default false
      public? true
      description "Kill switch — stops all heartbeats and blocks @mention dispatch"
    end

    attribute :pause_reason, :string do
      allow_nil? true
      public? true

      description """
      Visible reason the agent was auto-paused (e.g. failure-streak
      escalation). Cleared whenever the agent is unpaused.
      """
    end

    attribute :max_daily_runs, :integer do
      allow_nil? true
      public? true

      description "Max heartbeat + triggered runs per day. nil = unlimited (respects subscription limits)"
    end

    attribute :max_tokens_per_run, :integer do
      allow_nil? true
      public? true
      description "Max tokens per individual run. nil = unlimited (respects subscription limits)"
    end

    attribute :heartbeat_enabled, :boolean do
      default false
      public? true
      description "Enable proactive mode — agent self-schedules via Job system"
    end

    attribute :heartbeat_instructions, :string do
      allow_nil? true
      public? true
      description "Instructions for what to check on each heartbeat activation"
    end

    attribute :heartbeat_default_interval_minutes, :integer do
      default 360
      public? true
      constraints min: 5

      description "Default interval between heartbeats in minutes (min: 5). Agent can override per-run."
    end

    attribute :next_scheduled_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "Absolute datetime for next triage sweep. Takes precedence over interval."
    end

    attribute :deleted_at, :utc_datetime_usec do
      allow_nil? true
      public? false
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      allow_nil? false
    end

    belongs_to :model, Magus.Chat.Model do
      allow_nil? true
      public? true
      description "Pinned chat model for this agent"
    end

    belongs_to :image_model, Magus.Chat.Model do
      allow_nil? true
      public? true
      description "Pinned image generation model"
    end

    belongs_to :video_model, Magus.Chat.Model do
      allow_nil? true
      public? true
      description "Pinned video generation model"
    end

    belongs_to :workspace, Magus.Workspaces.Workspace do
      allow_nil? true
      public? true
    end

    has_many :conversations, Magus.Chat.Conversation
    has_many :integrations, Magus.Integrations.UserIntegration

    has_many :memories, Magus.Memory.Memory do
      destination_attribute :custom_agent_id
    end

    has_many :secrets, Magus.Agents.AgentSecret

    has_many :attachments, Magus.Agents.CustomAgentAttachment do
      destination_attribute :custom_agent_id
      public? true
    end
  end

  calculations do
    import Magus.Workspaces.Calculations

    calculate :image_url, :string, Magus.Agents.CustomAgent.Calculations.ImageUrl do
      public? true
      description "Resolved URL for the agent's profile image"
    end

    calculate :editable_by_actor,
              :boolean,
              Magus.Agents.CustomAgent.Calculations.EditableByActor do
      public? true
      description "Whether the current actor may update this agent (SPA inspect/edit split)"
    end

    calculate :is_watchdog_overdue, :boolean do
      public? false

      description """
      True when heartbeat is enabled, the agent isn't paused, and
      next_scheduled_at is more than 2x heartbeat_default_interval_minutes in
      the past. Gates the hourly watchdog Oban trigger.
      """

      calculation expr(
                    heartbeat_enabled == true and
                      is_paused == false and
                      not is_nil(next_scheduled_at) and
                      fragment(
                        "? < (now() at time zone 'utc') - (interval '1 minute' * ? * 2)",
                        next_scheduled_at,
                        heartbeat_default_interval_minutes
                      )
                  )
    end

    is_shared_to_workspace(:custom_agent)
  end

  identities do
    identity :unique_default, [:user_id], where: expr(is_default == true)

    identity :unique_handle_per_workspace, [:handle, :workspace_id],
      where: expr(not is_nil(workspace_id))

    identity :unique_handle_personal, [:handle, :user_id], where: expr(is_nil(workspace_id))
  end

  # --- Knowledge-section helpers (used by the generic actions above) ---

  @memory_kinds ~w(general fact hypothesis observation summary preference goal topic habit reflection)

  defp memory_map(memory) do
    %{
      id: memory.id,
      name: memory.name,
      summary: memory.summary,
      kind: to_string(memory.kind),
      confidence: memory.confidence
    }
  end

  defp safe_memory_kind(kind) when kind in @memory_kinds, do: String.to_existing_atom(kind)
  defp safe_memory_kind(_), do: :general

  defp clamp_confidence(value) when is_number(value), do: max(0.0, min(1.0, value / 1))
  defp clamp_confidence(_), do: 1.0

  defp resource_type_atom("brain"), do: :brain
  defp resource_type_atom("knowledge_collection"), do: :knowledge_collection
  defp resource_type_atom(_), do: nil

  defp agent_resource_granted?(resource_type, resource_id, agent_id, user) do
    case Magus.Workspaces.list_access_for_resource(resource_type, resource_id, actor: user) do
      {:ok, grants} ->
        Enum.any?(grants, &(&1.grantee_type == :custom_agent && &1.grantee_id == agent_id))

      _ ->
        false
    end
  end

  defp safe_attachment_mode("always"), do: :always
  defp safe_attachment_mode(_), do: :search

  defp attachment_map(attachment) do
    file = attachment.file

    %{
      id: attachment.id,
      mode: to_string(attachment.mode),
      position: attachment.position,
      file_id: attachment.file_id,
      file_name: file && file.name,
      file_type: file && to_string(file.type),
      file_size: file && file.file_size,
      file_status: file && to_string(file.status),
      token_count: attachment_token_count(file)
    }
  end

  # Sum of token_count across the file's chunks (loaded via `[file: [:chunks]]`).
  # The editor sums these across :always-mode attachments for the budget bar.
  defp attachment_token_count(%{chunks: chunks}) when is_list(chunks),
    do: Enum.reduce(chunks, 0, fn chunk, acc -> acc + (chunk.token_count || 0) end)

  defp attachment_token_count(_file), do: 0

  # The attachment join resource has no policies of its own, so gate mutations
  # on the actor's update access to the owning agent.
  defp assert_agent_editable(agent_id, actor) do
    case Magus.Agents.get_custom_agent(agent_id, actor: actor, load: [:editable_by_actor]) do
      {:ok, %{editable_by_actor: true}} -> :ok
      _ -> {:error, "not authorized to edit this agent"}
    end
  end

  @connectable_provider_keys ~w(telegram google_calendar rss_source api log_source simple_webhook)

  # Providers the SPA connect wizard can set up: every registered provider that
  # isn't a knowledge source (those have their own wizard) or the AI-guided
  # custom_api, with admin-only providers hidden from non-admins.
  defp connectable_providers(actor) do
    admin? = Map.get(actor || %{}, :is_admin, false) == true

    Magus.Integrations.list_available_providers()
    |> Enum.reject(&(&1.source_type == :knowledge or &1.key == :custom_api))
    |> Enum.reject(&(&1.requires_admin? and not admin?))
    |> Enum.map(&provider_meta_map/1)
  end

  defp provider_meta_map(meta) do
    %{
      key: to_string(meta.key),
      name: meta.name,
      description: meta.description,
      auth_type: to_string(meta.auth_type),
      source_type: to_string(meta.source_type),
      requires_admin: meta.requires_admin?,
      auth_fields:
        Enum.map(meta.auth_fields || [], fn field ->
          %{
            name: to_string(field[:name]),
            label: field[:label],
            type: to_string(field[:type] || :text),
            help: field[:help]
          }
        end)
    }
  end

  defp connect_agent_integration(agent_id, provider_key, credentials, config, actor)
       when is_binary(provider_key) do
    if provider_key in @connectable_provider_keys do
      provider_atom = String.to_existing_atom(provider_key)

      case Reactor.run(
             Magus.Integrations.Reactors.SetupIntegration,
             %{
               user_id: actor.id,
               custom_agent_id: agent_id,
               provider_key: provider_atom,
               credentials: credentials,
               config: config
             },
             async?: false
           ) do
        {:ok, integration} -> {:ok, connected_integration_map(integration, provider_atom)}
        {:error, reason} -> {:error, friendly_integration_error(reason)}
      end
    else
      {:error, "Unknown integration provider"}
    end
  end

  defp connected_integration_map(integration, provider_atom) do
    base = %{
      id: integration.id,
      provider_key: to_string(integration.provider_key),
      status: to_string(integration.status),
      auth_type: to_string(provider_auth_type(provider_atom))
    }

    # The API provider mints a one-time key during setup; surface it once so the
    # SPA can show it (afterwards it is only stored hashed + encrypted).
    if provider_atom == :api do
      case Magus.Integrations.load_credentials(integration.id) do
        {:ok, %{"api_key" => key}} when is_binary(key) -> Map.put(base, :api_key, key)
        _ -> base
      end
    else
      base
    end
  end

  defp provider_auth_type(provider_atom) do
    case Magus.Integrations.get_provider_module(provider_atom) do
      nil -> :none
      module -> module.auth_type()
    end
  end

  defp friendly_integration_error(reason) when is_binary(reason), do: reason
  defp friendly_integration_error(%{message: message}) when is_binary(message), do: message
  defp friendly_integration_error(reason), do: "Could not connect: #{inspect(reason)}"

  defp integration_map(integration, provider_meta) do
    meta =
      Map.get(provider_meta, integration.provider_key, %{
        name: to_string(integration.provider_key),
        source_type: :other
      })

    %{
      id: integration.id,
      provider_key: to_string(integration.provider_key),
      provider_name: meta.name,
      source_type: to_string(Map.get(meta, :source_type, :other)),
      status: to_string(integration.status),
      enabled_tools: Enum.map(integration.enabled_tools || [], &to_string/1),
      available_tools: available_tools_for(integration.provider_key),
      # Per-provider config for the management cards (feed urls, webhook secret,
      # thresholds, key prefix). The actor owns the integration; the API key is
      # NOT here (it lives in the encrypted credential).
      config: integration.config || %{}
    }
  end

  defp available_tools_for(provider_key) do
    module = Magus.Integrations.get_provider_module(provider_key)

    if module && function_exported?(module, :tools, 0) do
      Enum.map(module.tools(), fn tool ->
        %{key: to_string(tool.key), name: Map.get(tool, :name) || to_string(tool.key)}
      end)
    else
      []
    end
  end

  defp safe_tool_atom(tool) when is_binary(tool) do
    {:ok, String.to_existing_atom(tool)}
  rescue
    ArgumentError -> :error
  end

  # Mirrors the workbench disconnect_integration_impl: run the provider's
  # credential-removed hook, revoke the credential, then destroy the row.
  defp disconnect_integration(integration, user) do
    provider_module = Magus.Integrations.get_provider_module(integration.provider_key)

    case Ash.load(integration, [:credential], actor: user) do
      {:ok, %{credential: credential}} when not is_nil(credential) ->
        if provider_module && function_exported?(provider_module, :on_credentials_removed, 2) do
          provider_module.on_credentials_removed(integration, credential.encrypted_data || %{})
        end

        # Credentials have no policies; ownership was already verified by the
        # actor-scoped read of the integration above.
        Magus.Integrations.revoke_credential(credential, authorize?: false)

      _ ->
        :ok
    end

    Ash.destroy(integration, actor: user)
  end
end
