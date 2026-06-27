defmodule Magus.Chat.Conversation do
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Chat,
    extensions: [AshOban, AshTypescript.Resource],
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  oban do
    triggers do
      trigger :name_conversation do
        action :generate_name
        queue :conversations
        scheduler_cron "*/5 * * * *"
        read_action :read_for_scheduler
        worker_read_action :read_for_scheduler
        worker_module_name Magus.Chat.Message.Workers.NameConversation
        scheduler_module_name Magus.Chat.Message.Schedulers.NameConversation
        where expr(needs_title)
        debug? true
      end

      trigger :extract_turn_memories do
        action :extract_turn_memories
        queue :memory_extraction
        scheduler_cron "*/1 * * * *"
        read_action :read_for_scheduler
        worker_read_action :read_for_scheduler
        worker_module_name Magus.Chat.Conversation.Workers.ExtractTurnMemories
        scheduler_module_name Magus.Chat.Conversation.Schedulers.ExtractTurnMemories
        where expr(needs_extraction and not is_task_conversation)
      end

      trigger :cleanup_trashed do
        action :delete_full_conversation
        queue :conversation_cleanup
        scheduler_cron "@daily"
        read_action :trashed_for_cleanup
        worker_read_action :trashed_for_cleanup
        worker_module_name Magus.Chat.Conversation.Workers.CleanupTrashed
        scheduler_module_name Magus.Chat.Conversation.Schedulers.CleanupTrashed
      end
    end
  end

  @unfiled_conversations_limit Application.compile_env(
                                 :magus,
                                 [Magus.Chat, :unfiled_conversations_limit],
                                 20
                               )

  typescript do
    type_name "Conversation"
  end

  postgres do
    table "conversations"
    repo Magus.Repo
  end

  actions do
    # No default :destroy — always use :delete_full_conversation to ensure
    # external resources (file storage, sandbox sprites) are cleaned up.

    read :read do
      primary? true
      pagination keyset?: true, required?: false
    end

    read :read_for_scheduler do
      pagination keyset?: true, required?: false
      filter expr(is_nil(deleted_at))
    end

    read :trashed do
      description "Get the current user's soft-deleted conversations"
      pagination keyset?: true, required?: false
      filter expr(user_id == ^actor(:id) and not is_nil(deleted_at))
      prepare build(sort: [deleted_at: :desc])
    end

    create :create do
      accept [
        :title,
        :folder_id,
        :chat_mode,
        :selected_model_id,
        :custom_agent_id,
        :skill_context,
        :skill_tools,
        :loaded_tools,
        :is_task_conversation,
        :parent_conversation_id,
        :sandbox_conversation_id,
        :system_prompt,
        :workspace_id
      ]

      change relate_actor(:user)
      change {Magus.Chat.Folder.Changes.PromoteKindForContent, content_kind: :conversations}
    end

    create :create_thread do
      accept [:title]

      argument :parent_conversation_id, :uuid, allow_nil?: false
      argument :branched_at_message_id, :uuid, allow_nil?: false

      change relate_actor(:user)
      change set_attribute(:is_task_conversation, false)
      change Magus.Chat.Conversation.Changes.CreateThread
    end

    action :start_skill_conversation, :struct do
      description "Create a conversation seeded with a skill's context/tools and send its start message (classic ?skill= deeplink)."
      constraints instance_of: __MODULE__

      argument :skill_name, :string, allow_nil?: false
      argument :topic, :string, allow_nil?: true
      argument :workspace_id, :uuid, allow_nil?: true

      run fn input, ctx ->
        Magus.Chat.SkillConversation.start(
          input.arguments.skill_name,
          input.arguments.topic,
          input.arguments.workspace_id,
          ctx.actor
        )
      end
    end

    action :send_now_queued, :atom do
      description "Deliver the conversation's queued steering messages now."
      argument :conversation_id, :uuid, allow_nil?: false

      run fn input, context ->
        conv_id = input.arguments.conversation_id

        # Actor-scoped read enforces the member-only read policy: a non-member
        # gets a NotFound/Forbidden here, so send_now is never reached without
        # access. The action-level policy is only actor_present(); this read is
        # the real authorization gate.
        case Magus.Chat.get_conversation(conv_id, actor: context.actor) do
          {:ok, _conversation} ->
            Magus.Agents.Steering.send_now(conv_id)
            {:ok, :ok}

          {:error, _} = error ->
            error
        end
      end
    end

    update :set_model do
      accept [:selected_model_id]
    end

    update :set_image_model do
      accept [:selected_image_model_id]
    end

    update :set_video_model do
      accept [:selected_video_model_id]
    end

    update :generate_name do
      accept []
      transaction? false
      require_atomic? false
      change Magus.Chat.Conversation.Changes.GenerateName
    end

    update :schedule_extraction do
      accept [:extraction_due_at]
      require_atomic? false
    end

    update :extract_turn_memories do
      accept []
      transaction? false
      require_atomic? false
      change Magus.Chat.Conversation.Changes.ExtractTurnMemories
    end

    read :my_conversations do
      filter expr(
               user_id == ^actor(:id) and is_task_conversation != true and is_thread != true and
                 is_nil(deleted_at) and is_nil(companion_link.id)
             )
    end

    read :my_task_conversations do
      description "Get the current user's active task conversations"
      filter expr(user_id == ^actor(:id) and is_task_conversation == true and is_nil(deleted_at))
      prepare build(load: [:parent_conversation], sort: [updated_at: :desc])
    end

    read :my_favorites do
      description "Get the current user's favorite conversations"

      filter expr(
               exists(favorites, user_id == ^actor(:id)) and is_task_conversation != true and
                 is_thread != true and is_nil(deleted_at) and is_nil(companion_link.id)
             )

      prepare build(load: [:last_message_at], sort: [last_message_at: :desc_nils_last])
    end

    read :personal_favorites do
      description "User's favorited conversations not in any workspace"

      filter expr(
               exists(favorites, user_id == ^actor(:id)) and
                 is_nil(deleted_at) and
                 is_nil(workspace_id) and
                 is_task_conversation != true and
                 is_thread != true and
                 is_nil(companion_link.id)
             )

      prepare build(load: [:last_message_at], sort: [last_message_at: :desc_nils_last])
    end

    read :workspace_favorites do
      description "User's favorited conversations in the given workspace"
      argument :workspace_id, :uuid, allow_nil?: false

      filter expr(
               exists(favorites, user_id == ^actor(:id)) and
                 is_task_conversation != true and
                 is_thread != true and
                 is_nil(deleted_at) and
                 workspace_id == ^arg(:workspace_id) and
                 is_nil(companion_link.id)
             )

      prepare build(
                load: [:last_message_at, :is_shared_to_workspace],
                sort: [last_message_at: :desc_nils_last]
              )
    end

    read :unfiled_conversations do
      filter expr(
               user_id == ^actor(:id) and is_nil(folder_id) and
                 is_task_conversation != true and is_thread != true and
                 is_nil(workspace_id) and is_nil(deleted_at) and
                 is_nil(companion_link.id)
             )

      prepare build(
                load: [:last_message_at],
                sort: [last_message_at: :desc_nils_last],
                limit: @unfiled_conversations_limit
              )
    end

    read :workspace_conversations do
      description "Get conversations visible in a workspace (own + shared via workspace grant)"
      argument :workspace_id, :uuid, allow_nil?: false

      # Visibility (creator vs. workspace grant) is enforced by the read policy
      # via `Magus.Workspaces.AccessCheck`. Do not duplicate that check here with
      # `exists(ResourceAccess, ...)`: a user-written exists on ResourceAccess
      # causes Ash to apply ResourceAccess's own read policy to every
      # ResourceAccess subquery in the query (including AccessCheck's), which
      # restricts visible grants to `grantee_type=:user, grantee_id=actor`. That
      # makes :workspace grants invisible and hides shared conversations from
      # other workspace members.
      filter expr(
               workspace_id == ^arg(:workspace_id) and
                 is_task_conversation != true and
                 is_thread != true and
                 is_nil(deleted_at) and
                 is_nil(companion_link.id)
             )

      # Bounded like :personal_conversations — the nav doesn't need every
      # conversation a workspace ever produced, and the sort computes the
      # last_message_at aggregate for each candidate row.
      prepare build(
                load: [:last_message_at, :is_shared_to_workspace],
                sort: [last_message_at: :desc_nils_last],
                limit: 100
              )
    end

    read :personal_conversations do
      description "User-owned conversations with no workspace_id."

      filter expr(
               is_nil(workspace_id) and is_nil(deleted_at) and user_id == ^actor(:id) and
                 is_task_conversation != true and is_thread != true and
                 is_nil(companion_link.id)
             )

      prepare build(load: [:last_message_at], sort: [updated_at: :desc], limit: 100)
    end

    read :filed_conversations do
      description "User-owned personal conversations that live inside a folder."

      # No limit: a folder must always show all of its conversations. The nav's
      # quick-access list (`:unfiled_conversations`) is the capped one; the full
      # archive lives in the paginated history view.
      filter expr(
               user_id == ^actor(:id) and not is_nil(folder_id) and
                 is_task_conversation != true and is_thread != true and
                 is_nil(workspace_id) and is_nil(deleted_at) and
                 is_nil(companion_link.id)
             )

      prepare build(load: [:last_message_at], sort: [last_message_at: :desc_nils_last])
    end

    read :threads_for_conversation do
      argument :conversation_id, :uuid, allow_nil?: false

      filter expr(
               parent_conversation_id == ^arg(:conversation_id) and is_thread == true and
                 is_nil(deleted_at)
             )

      prepare build(sort: [inserted_at: :asc])
    end

    read :threads_for_conversations do
      argument :conversation_ids, {:array, :uuid}, allow_nil?: false

      filter expr(
               parent_conversation_id in ^arg(:conversation_ids) and is_thread == true and
                 is_nil(deleted_at)
             )

      prepare build(sort: [inserted_at: :asc])
    end

    read :fulltext_search do
      description "Full-text search across conversations using PostgreSQL tsvector + pg_trgm"
      argument :query, :string, allow_nil?: false
      pagination offset?: true, default_limit: 20, countable: false
      filter expr(is_nil(deleted_at))

      prepare fn query, _context ->
        require Ash.Query

        search_term = Ash.Query.get_argument(query, :query)

        query
        |> Ash.Query.filter(
          fragment(
            "search_vector @@ plainto_tsquery('simple', ?) OR similarity(title, ?) > 0.3",
            ^search_term,
            ^search_term
          )
        )
      end
    end

    update :move_to_folder do
      accept [:folder_id]
      # Required so the PromoteKindForContent after_action can run.
      require_atomic? false

      # Same container rules as File.move_to_context / Folder.move_to_folder:
      # the destination must be the actor's own folder, in the same workspace.
      validate {Magus.Chat.Folder.Validations.ActorOwnsFolderField, required?: false}
      validate Magus.Workspaces.Validations.FolderInSameWorkspace

      change {Magus.Chat.Folder.Changes.PromoteKindForContent, content_kind: :conversations}

      change {Magus.Chat.Folder.Changes.SyncWorkspaceShareWithFolder,
              container_field: :folder_id,
              share_action: :share_to_team,
              unshare_action: :unshare_from_team}
    end

    update :soft_delete do
      accept []
      change set_attribute(:deleted_at, &DateTime.utc_now/0)
    end

    update :restore do
      accept []
      change set_attribute(:deleted_at, nil)
    end

    read :history do
      description "Paginated history of the actor's conversations for the history view, with optional full-text search across titles and message contents."

      argument :query, :string, allow_nil?: true
      argument :workspace_id, :uuid, allow_nil?: true

      pagination offset?: true, countable: true, default_limit: 25

      filter expr(
               user_id == ^actor(:id) and is_task_conversation != true and is_thread != true and
                 is_nil(deleted_at) and is_nil(companion_link.id) and
                 ((is_nil(^arg(:workspace_id)) and is_nil(workspace_id)) or
                    workspace_id == ^arg(:workspace_id))
             )

      prepare build(sort: [updated_at: :desc], load: [:message_count, :last_message_at])

      prepare fn query, _context ->
        require Ash.Query

        case Ash.Query.get_argument(query, :query) do
          empty when empty in [nil, ""] ->
            query

          search_term ->
            # Classic unified search: conversation tsvector/title similarity
            # OR any message matching. Unqualified columns resolve to their
            # own binding (messages inside exists, conversations outside).
            Ash.Query.filter(
              query,
              fragment(
                "search_vector @@ plainto_tsquery('simple', ?) OR similarity(title, ?) > 0.3",
                ^search_term,
                ^search_term
              ) or
                exists(
                  messages,
                  fragment("search_vector @@ plainto_tsquery('simple', ?)", ^search_term)
                )
            )
        end
      end
    end

    destroy :delete_full_conversation do
      require_atomic? false
      change Magus.Chat.Conversation.Changes.DeleteFullConversation
      change {Magus.Workspaces.Changes.DestroyResourceGrants, resource_type: :conversation}
    end

    read :trashed_for_cleanup do
      description "Get conversations soft-deleted more than 30 days ago for permanent deletion"
      pagination keyset?: true, required?: false
      filter expr(not is_nil(deleted_at) and deleted_at < ago(30, :day))
    end

    update :enable_multiplayer do
      require_atomic? false
      change set_attribute(:is_multiplayer, true)
      change Magus.Chat.Conversation.Changes.AddOwnerAsMember
    end

    update :disable_multiplayer do
      require_atomic? false
      change set_attribute(:is_multiplayer, false)
      change Magus.Chat.Conversation.Changes.RemoveNonOwnerMembers
    end

    update :rename do
      require_atomic? false
      accept [:title]
    end

    update :update_visibility do
      accept [:visibility]
    end

    update :share_to_team do
      accept []
      require_atomic? false
      validate present(:workspace_id), message: "conversation must belong to a workspace"

      change {Magus.Workspaces.Changes.GrantWorkspaceAccess, resource_type: :conversation}
    end

    update :unshare_from_team do
      accept []
      require_atomic? false
      validate present(:workspace_id), message: "conversation must belong to a workspace"

      change {Magus.Workspaces.Changes.RevokeWorkspaceAccess, resource_type: :conversation}

      change after_action(fn _cs, conv, _context ->
               # Tell connected non-owner viewers that their access may have
               # been revoked so they can re-authorize and navigate away if
               # they no longer have read access to this conversation.
               Magus.Endpoint.broadcast(
                 "chat:access:#{conv.id}",
                 "access_revoked",
                 %{conversation_id: conv.id}
               )

               {:ok, conv}
             end)
    end

    update :mark_memory_consolidated do
      accept [:last_memory_consolidation_at]
      require_atomic? false
    end

    update :set_mode do
      accept [:chat_mode]
    end

    update :update_image_generation_settings do
      accept [:image_generation_settings]
      require_atomic? false

      change fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :image_generation_settings) do
          nil ->
            changeset

          settings ->
            Ash.Changeset.force_change_attribute(
              changeset,
              :image_generation_settings,
              Magus.Agents.ImageGenerationConfig.sanitize(settings)
            )
        end
      end
    end

    update :update_video_generation_settings do
      accept [:video_generation_settings]
      require_atomic? false

      change fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :video_generation_settings) do
          nil ->
            changeset

          settings ->
            Ash.Changeset.force_change_attribute(
              changeset,
              :video_generation_settings,
              Magus.Agents.VideoGenerationConfig.sanitize(settings)
            )
        end
      end
    end

    update :update_settings do
      accept [:system_prompt, :sampling_settings]
    end

    update :set_skill do
      accept [:skill_context, :skill_tools]
    end

    update :set_loaded_tools do
      accept [:loaded_tools]
    end

    update :reset_settings do
      change set_attribute(:system_prompt, nil)
      change set_attribute(:sampling_settings, nil)
    end

    update :activate_system_prompt do
      argument :prompt_id, :uuid, allow_nil?: false
      require_atomic? false

      change fn changeset, context ->
        prompt_id = Ash.Changeset.get_argument(changeset, :prompt_id)

        # The actor must be able to read the prompt before it is linked:
        # without this, any readable conversation could reference a foreign
        # private prompt by UUID (and the after_action below would apply that
        # prompt's model/mode). Internal callers with authorize?: false skip it.
        with_readable_prompt =
          if context.authorize? do
            case Magus.Library.get_prompt(prompt_id, Ash.Context.to_opts(context)) do
              {:ok, _prompt} -> :ok
              {:error, _} -> :error
            end
          else
            :ok
          end

        case with_readable_prompt do
          :error ->
            Ash.Changeset.add_error(changeset,
              field: :prompt_id,
              message: "prompt not found"
            )

          :ok ->
            apply_system_prompt(changeset, prompt_id)
        end
      end
    end

    update :deactivate_system_prompt do
      change set_attribute(:system_prompt_id, nil)
    end

    update :record_skill_approval do
      require_atomic? false
      argument :skill_id, :uuid, allow_nil?: false

      change fn changeset, _context ->
        id = Ash.Changeset.get_argument(changeset, :skill_id)
        existing = Ash.Changeset.get_attribute(changeset, :approved_skill_ids) || []
        Ash.Changeset.change_attribute(changeset, :approved_skill_ids, Enum.uniq([id | existing]))
      end
    end

    action :build_message_history, {:array, :struct} do
      argument :conversation_id, :uuid, allow_nil?: false
      argument :current_message_id, :uuid
      argument :is_multiplayer, :boolean, default: false

      run Magus.Chat.Conversation.Actions.BuildMessageHistory
    end

    action :build_thread_message_history, {:array, :struct} do
      argument :conversation_id, :uuid, allow_nil?: false
      argument :current_message_id, :uuid
      argument :is_multiplayer, :boolean, default: false

      run Magus.Chat.Conversation.Actions.BuildThreadMessageHistory
    end
  end

  policies do
    import Magus.Workspaces.Policies

    # AshOban triggers bypass authorization completely
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # AI agents need to read conversations for context building
    bypass action_type(:read) do
      authorize_if Magus.Checks.IsAiAgent
    end

    # Generic workspace-scoped policies: creator ownership, workspace-admin
    # management, and per-grantee access via resource_accesses. Extras preserve
    # multiplayer ConversationMember read/update paths.
    workspace_scoped_policies(
      resource_type: :conversation,
      extra_read: [
        quote do
          authorize_if expr(exists(members, user_id == ^actor(:id) and not is_nil(accepted_at)))
        end
      ],
      extra_update: [
        quote do
          authorize_if expr(exists(members, user_id == ^actor(:id) and role == :owner))
        end
      ]
    )

    # Sharing is reserved for the creator (and workspace admins): an editor
    # grant allows editing content, not changing who can see it. ANDs with the
    # generic update policy above. Matches the classic owner-gated nav action.
    policy action([:share_to_team, :unshare_from_team]) do
      authorize_if expr(user_id == ^actor(:id))
      authorize_if Magus.Checks.ActorCanManageWorkspaceResource
    end

    # Skill-seeded creation: the run path calls create_conversation under the
    # actor (workspace_scoped create policy applies), so actor_present suffices.
    policy action(:start_skill_conversation) do
      authorize_if actor_present()
    end

    # Steering delivery: the run path does an actor-scoped get_conversation read
    # (member-only read policy applies), so actor_present suffices here. NOT a
    # blanket bypass: it triggers agent work / message delivery and must remain
    # access-controlled via the in-run read.
    policy action(:send_now_queued) do
      authorize_if actor_present()
    end

    # Preserve existing per-action bypasses
    bypass action(:mark_memory_consolidated) do
      authorize_if always()
    end

    bypass action(:schedule_extraction) do
      authorize_if always()
    end

    bypass action(:set_skill) do
      authorize_if always()
    end

    bypass action(:set_loaded_tools) do
      authorize_if always()
    end

    bypass action(:extract_turn_memories) do
      authorize_if always()
    end

    # Generic actions - bypass since they're read-only
    # and called from already-authorized contexts (chat view, respond change)
    bypass action(:build_message_history) do
      authorize_if always()
    end

    bypass action(:build_thread_message_history) do
      authorize_if always()
    end
  end

  pub_sub do
    module MagusWeb.Endpoint
    prefix "chat"

    publish_all :create, ["conversations", :user_id] do
      transform & &1.data
    end

    publish_all :update, ["conversations", :id] do
      transform & &1.data
    end

    publish_all :destroy, ["conversations", :user_id] do
      event "destroy"
      transform & &1.data
    end

    # Title changes (manual rename + Oban auto-name) also broadcast on the
    # user-scoped topic so the chat nav can refresh without subscribing per
    # conversation. The per-id `:update` broadcast above is what conversation
    # views subscribe to for their own header refresh.
    publish :rename, ["conversations", :user_id] do
      event "title_changed"
      transform & &1.data
    end

    publish :generate_name, ["conversations", :user_id] do
      event "title_changed"
      transform & &1.data
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :title, :string do
      public? true
    end

    attribute :is_multiplayer, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :visibility, :atom do
      allow_nil? false
      default :invite_only
      constraints one_of: [:invite_only, :public]
      public? true

      description "invite_only: only invited emails can join. public: anyone with a link can join."
    end

    attribute :chat_mode, :atom do
      allow_nil? false
      default :chat
      constraints one_of: [:chat, :search, :reasoning, :image_generation, :video_generation]
      public? true
      description "Current chat mode for this conversation"
    end

    attribute :system_prompt, :string do
      public? true
      allow_nil? true
      description "Custom system prompt for this conversation"
    end

    attribute :skill_context, :string do
      public? true
      allow_nil? true
      description "Pre-loaded skill content for wizard/onboarding flows"
    end

    attribute :skill_tools, {:array, :string} do
      public? true
      allow_nil? true
      description "Tool names declared by the skill for this conversation"
    end

    attribute :loaded_tools, {:array, :string} do
      public? true
      allow_nil? true
      description "Tool names discovered via tool_search and loaded into this conversation"
    end

    attribute :approved_skill_ids, {:array, :uuid} do
      allow_nil? true
      default []
      public? true
      description "Skill ids the user has approved to run bundled code in this conversation"
    end

    attribute :sampling_settings, :map do
      public? true
      allow_nil? true
      description "LLM sampling settings (temperature, max_tokens, top_p, top_k)"
    end

    attribute :image_generation_settings, :map do
      public? true
      allow_nil? true
      description "Image generation config (aspect_ratio, image_size)"
    end

    attribute :video_generation_settings, :map do
      public? true
      allow_nil? true
      description "Video generation config (aspect_ratio, duration, resolution, generate_audio)"
    end

    attribute :is_task_conversation, :boolean do
      allow_nil? false
      default false
      public? true
      description "Whether this is a background task conversation spawned by another conversation"
    end

    attribute :is_thread, :boolean do
      allow_nil? false
      default false
      public? true
      description "Whether this is a thread branching from a message in the parent conversation"
    end

    attribute :branched_at, :utc_datetime_usec do
      allow_nil? true
      public? true

      description "Timestamp of the message this thread branches from (fallback if message deleted)"
    end

    attribute :deleted_at, :utc_datetime_usec do
      allow_nil? true
      # Readable so the trash view can show when something was deleted; all
      # writes still go through soft_delete/restore (not in any accept list).
      public? true
      description "When set, the conversation is in the trash"
    end

    attribute :extraction_due_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :last_memory_consolidation_at, :utc_datetime_usec do
      allow_nil? true
      public? false
    end

    # Public so API clients can sort the conversation nav by recency.
    timestamps public?: true
  end

  relationships do
    has_many :messages, Magus.Chat.Message do
      public? true
    end

    has_many :members, Magus.Chat.ConversationMember do
      public? true
    end

    has_many :invite_links, Magus.Chat.ConversationInviteLink do
      public? true
    end

    has_many :invitations, Magus.Chat.ConversationInvitation do
      public? true
    end

    has_many :share_links, Magus.Chat.ConversationShareLink do
      public? true
    end

    belongs_to :user, Magus.Accounts.User do
      public? true
      allow_nil? false
    end

    belongs_to :folder, Magus.Chat.Folder do
      public? true
      allow_nil? true
    end

    belongs_to :selected_model, Magus.Chat.Model do
      public? true
      allow_nil? true
      description "Preferred model for this conversation (chat mode)"
    end

    belongs_to :selected_image_model, Magus.Chat.Model do
      public? true
      allow_nil? true
      description "Preferred model for image generation mode"
    end

    belongs_to :selected_video_model, Magus.Chat.Model do
      public? true
      allow_nil? true
      description "Preferred model for video generation mode"
    end

    belongs_to :active_system_prompt, Magus.Library.Prompt do
      public? true
      allow_nil? true
      source_attribute :system_prompt_id

      description "Active system prompt providing persona instructions and optional model/mode presets"
    end

    belongs_to :custom_agent, Magus.Agents.CustomAgent do
      public? true
      allow_nil? true
      description "The custom agent powering this conversation (nil = legacy conversation)"
    end

    belongs_to :workspace, Magus.Workspaces.Workspace do
      allow_nil? true
      public? true
    end

    belongs_to :parent_conversation, __MODULE__ do
      public? true
      allow_nil? true
      description "The parent conversation (for task conversations and threads)"
    end

    belongs_to :sandbox_conversation, __MODULE__ do
      public? true
      allow_nil? true

      description "The conversation whose sandbox this conversation shares. If nil, uses own sandbox."
    end

    belongs_to :branched_at_message, Magus.Chat.Message do
      public? true
      allow_nil? true
      attribute_writable? true
      description "The message in the parent conversation that this thread branches from"
    end

    has_many :child_conversations, __MODULE__ do
      public? true
      destination_attribute :parent_conversation_id
    end

    has_many :favorites, Magus.Chat.ConversationFavorite do
      public? true
    end

    has_many :memories, Magus.Memory.Memory do
      public? true
    end

    has_one :companion_link, Magus.Chat.ConversationCompanion do
      destination_attribute :conversation_id
    end
  end

  calculations do
    import Magus.Workspaces.Calculations

    calculate :needs_title, :boolean do
      calculation expr(
                    is_nil(title) and
                      (count(messages) > 3 or
                         (count(messages) > 1 and inserted_at < ago(10, :minute)))
                  )
    end

    calculate :member_count, :integer do
      calculation expr(count(members, query: [filter: expr(not is_nil(accepted_at))]))
    end

    calculate :is_shared, :boolean do
      calculation expr(is_multiplayer and member_count > 1)
    end

    calculate :has_active_share_links, :boolean do
      calculation expr(count(share_links, query: [filter: expr(is_active == true)]) > 0)
    end

    calculate :is_favorited, :boolean do
      public? true
      calculation expr(exists(favorites, user_id == ^actor(:id)))
    end

    calculate :needs_extraction, :boolean do
      calculation expr(not is_nil(extraction_due_at) and extraction_due_at < now())
    end

    is_shared_to_workspace(:conversation)

    calculate :is_collaborative, :boolean do
      description "True when the conversation should render collaborative UI (avatars, peer message bubbles, typing indicators)"
      calculation expr(is_multiplayer or is_shared_to_workspace)
    end
  end

  aggregates do
    count :message_count, :messages do
      public? true
    end

    max :last_message_at, :messages, :inserted_at do
      public? true
    end
  end

  # Sets the system prompt FK and, after commit, applies the prompt's model
  # and chat mode to the conversation (system-level: the actor was already
  # verified to be able to read the prompt in the change above).
  defp apply_system_prompt(changeset, prompt_id) do
    changeset
    |> Ash.Changeset.change_attribute(:system_prompt_id, prompt_id)
    |> Ash.Changeset.after_action(fn _changeset, record ->
      case Magus.Library.get_prompt(prompt_id, load: [:model], authorize?: false) do
        {:ok, prompt} ->
          record =
            if prompt.model_id do
              {:ok, updated} =
                record
                |> Ash.Changeset.for_update(:set_model, %{selected_model_id: prompt.model_id},
                  authorize?: false
                )
                |> Ash.update()

              updated
            else
              record
            end

          if prompt.chat_mode do
            {:ok, _} =
              record
              |> Ash.Changeset.for_update(:set_mode, %{chat_mode: prompt.chat_mode},
                authorize?: false
              )
              |> Ash.update()
          end

          # Reload to get updated values
          Magus.Chat.get_conversation(record.id, authorize?: false)

        {:error, _} ->
          {:ok, record}
      end
    end)
  end
end
