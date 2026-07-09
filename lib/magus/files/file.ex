defmodule Magus.Files.File do
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Files,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban, AshTypescript.Resource],
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub]

  postgres do
    table "files"
    repo Magus.Repo

    base_filter_sql "deleted_at IS NULL"
    identity_wheres_to_sql unique_collection_external: "knowledge_collection_id IS NOT NULL"
  end

  oban do
    triggers do
      trigger :process_file do
        action :process
        queue :file_processing
        scheduler_cron false
        worker_module_name Magus.Files.File.Workers.ProcessFile
        scheduler_module_name Magus.Files.File.Schedulers.ProcessFile
        where expr(status == :pending)
      end

      trigger :retry_transient_processing do
        action :reprocess
        queue :file_processing
        scheduler_cron "*/30 * * * *"
        where expr(status == :error and transient_error == true and processing_attempts < 4)
        worker_module_name Magus.Files.File.Workers.RetryTransientProcessing
        scheduler_module_name Magus.Files.File.Schedulers.RetryTransientProcessing
      end

      # Mirrors the KnowledgeCollection stuck-:syncing watchdog: a crash
      # between the chunk-destroy and chunk-insert steps of ProcessFile
      # (non-transactional by design, see process_file.ex) can leave a file
      # stuck in :processing forever, since neither the :process trigger
      # (wants :pending) nor the retry trigger (wants :error) would pick it
      # up again. This trigger reclaims it back to :pending so processing
      # retries. Bounded by processing_attempts < 4, same budget as the
      # transient-retry trigger, so a crash-looping file cannot retry forever.
      trigger :recover_stuck_processing do
        action :recover_stuck_processing
        queue :file_processing
        scheduler_cron "*/30 * * * *"

        where expr(
                status == :processing and updated_at < ago(30, :minute) and
                  processing_attempts < 4
              )

        worker_module_name Magus.Files.File.Workers.RecoverStuckProcessing
        scheduler_module_name Magus.Files.File.Schedulers.RecoverStuckProcessing
      end
    end
  end

  typescript do
    type_name "File"
  end

  resource do
    base_filter expr(is_nil(deleted_at))
  end

  actions do
    destroy :destroy do
      primary? true
      require_atomic? false
      change Magus.Files.File.Changes.DeleteFile
      change Magus.Files.File.Changes.BroadcastWorkspaceEvent
      change {Magus.Workspaces.Changes.DestroyResourceGrants, resource_type: :file}
      change {Magus.Chat.Changes.UnlinkCompanions, resource_type: :file}
    end

    read :read do
      primary? true
      pagination keyset?: true, required?: false
    end

    read :my_files do
      filter expr(
               user_id == ^actor(:id) or
                 (not is_nil(workspace_id) and
                    exists(workspace.members, is_active == true and user_id == ^actor(:id)))
             )

      prepare build(sort: [inserted_at: :desc])
    end

    read :for_conversation do
      argument :conversation_id, :uuid, allow_nil?: false
      filter expr(conversation_id == ^arg(:conversation_id))
      prepare build(sort: [inserted_at: :desc])
    end

    read :for_folder do
      argument :folder_id, :uuid, allow_nil?: false
      filter expr(folder_id == ^arg(:folder_id))
      prepare build(sort: [inserted_at: :desc])
    end

    read :global_files do
      description "Get files that are not tied to any conversation or folder (user's global files)"
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id) and is_nil(conversation_id) and is_nil(folder_id))
      prepare build(sort: [inserted_at: :desc])
    end

    read :for_workspace do
      argument :workspace_id, :uuid, allow_nil?: false
      filter expr(workspace_id == ^arg(:workspace_id))
      prepare build(sort: [inserted_at: :desc])
    end

    read :personal_library_files do
      description "User-owned files with no workspace_id and no conversation_id."

      argument :browser_type, :string, allow_nil?: true, default: nil
      argument :browser_modified, :string, allow_nil?: true, default: nil
      argument :browser_source, :string, allow_nil?: true, default: nil

      filter expr(
               user_id == ^actor(:id) and
                 is_nil(workspace_id) and
                 is_nil(conversation_id) and
                 is_nil(deleted_at)
             )

      prepare build(sort: [updated_at: :desc])
      prepare Magus.Files.File.Preparations.ApplyBrowserFilters
    end

    read :workspace_library_files do
      description "Workspace-scoped files with no conversation_id."
      argument :workspace_id, :uuid, allow_nil?: false
      argument :browser_type, :string, allow_nil?: true, default: nil
      argument :browser_modified, :string, allow_nil?: true, default: nil
      argument :browser_source, :string, allow_nil?: true, default: nil

      filter expr(
               workspace_id == ^arg(:workspace_id) and
                 is_nil(conversation_id) and
                 is_nil(deleted_at)
             )

      prepare build(load: [:is_shared_to_workspace], sort: [updated_at: :desc])
      prepare Magus.Files.File.Preparations.ApplyBrowserFilters
    end

    read :list_in_folder do
      description "Files in a specific folder; respects access policies."
      argument :folder_id, :uuid, allow_nil?: false
      argument :browser_type, :string, allow_nil?: true, default: nil
      argument :browser_modified, :string, allow_nil?: true, default: nil
      argument :browser_source, :string, allow_nil?: true, default: nil

      filter expr(folder_id == ^arg(:folder_id) and is_nil(deleted_at))
      prepare build(load: [:is_shared_to_workspace], sort: [updated_at: :desc])
      prepare Magus.Files.File.Preparations.ApplyBrowserFilters
    end

    read :list_recent do
      description "Files updated since `since`, scoped to actor's personal library or workspace."
      argument :workspace_id, :uuid, allow_nil?: true
      argument :since, :utc_datetime_usec, allow_nil?: false
      argument :browser_type, :string, allow_nil?: true, default: nil
      argument :browser_modified, :string, allow_nil?: true, default: nil
      argument :browser_source, :string, allow_nil?: true, default: nil

      filter expr(
               updated_at >= ^arg(:since) and
                 is_nil(deleted_at) and
                 ((is_nil(^arg(:workspace_id)) and user_id == ^actor(:id) and
                     is_nil(workspace_id)) or
                    (not is_nil(^arg(:workspace_id)) and
                       workspace_id == ^arg(:workspace_id)))
             )

      prepare build(load: [:is_shared_to_workspace], sort: [updated_at: :desc])
      prepare Magus.Files.File.Preparations.ApplyBrowserFilters
    end

    read :list_shared_with_me do
      description "Workspace files the actor did not create but can access."
      argument :workspace_id, :uuid, allow_nil?: false
      argument :browser_type, :string, allow_nil?: true, default: nil
      argument :browser_modified, :string, allow_nil?: true, default: nil
      argument :browser_source, :string, allow_nil?: true, default: nil

      filter expr(
               workspace_id == ^arg(:workspace_id) and
                 user_id != ^actor(:id) and
                 is_nil(deleted_at)
             )

      prepare build(load: [:is_shared_to_workspace], sort: [updated_at: :desc])
      prepare Magus.Files.File.Preparations.ApplyBrowserFilters
    end

    read :list_trash do
      description "Soft-deleted files belonging to the actor's scope."
      argument :workspace_id, :uuid, allow_nil?: true
      argument :browser_type, :string, allow_nil?: true, default: nil
      argument :browser_modified, :string, allow_nil?: true, default: nil
      argument :browser_source, :string, allow_nil?: true, default: nil

      # NOTE: trash filter is installed by the IncludeTrashed preparation
      # because the resource-level `base_filter expr(is_nil(deleted_at))`
      # would AND with `not is_nil(deleted_at)` and short-circuit to `false`.
      prepare Magus.Files.File.Preparations.IncludeTrashed
      prepare build(sort: [deleted_at: :desc])
      prepare Magus.Files.File.Preparations.ApplyBrowserFilters
    end

    read :list_templates do
      description "List files marked as templates accessible to the actor, optionally filtered by a name substring."
      argument :query, :string, allow_nil?: true, default: nil
      argument :browser_type, :string, allow_nil?: true, default: nil
      argument :browser_modified, :string, allow_nil?: true, default: nil
      argument :browser_source, :string, allow_nil?: true, default: nil

      filter expr(
               is_template == true and is_nil(deleted_at) and
                 (is_nil(^arg(:query)) or
                    contains(fragment("lower(?)", name), fragment("lower(?)", ^arg(:query))))
             )

      prepare build(sort: [updated_at: :desc])
      prepare Magus.Files.File.Preparations.ApplyBrowserFilters
    end

    read :files_for_collection do
      description "Files synced from a specific knowledge collection."
      argument :knowledge_collection_id, :uuid, allow_nil?: false
      argument :browser_type, :string, allow_nil?: true, default: nil
      argument :browser_modified, :string, allow_nil?: true, default: nil
      argument :browser_source, :string, allow_nil?: true, default: nil

      filter expr(
               knowledge_collection_id == ^arg(:knowledge_collection_id) and
                 is_nil(deleted_at)
             )

      prepare build(sort: [name: :asc])
      prepare Magus.Files.File.Preparations.ApplyBrowserFilters
    end

    read :fulltext_search do
      description "Full-text search across files using PostgreSQL tsvector + pg_trgm"
      argument :query, :string, allow_nil?: false
      pagination offset?: true, default_limit: 20, countable: false

      prepare fn query, context ->
        require Ash.Query

        search_term = Ash.Query.get_argument(query, :query)
        actor = context.actor

        # Use subquery to avoid ambiguous column reference (search_vector exists in both
        # files and conversations tables). Security: Users can search their own files
        # or files in conversations they can access.
        base_query =
          case actor do
            # AI agent can search all files (used by tools)
            %Magus.Agents.Support.AiAgent{} ->
              query

            %{id: user_id} ->
              query
              |> Ash.Query.filter(
                fragment(
                  """
                  user_id = ?::uuid OR conversation_id IN (
                    SELECT c.id FROM conversations c
                    WHERE c.user_id = ?::uuid
                    UNION
                    SELECT cm.conversation_id FROM conversation_members cm
                    WHERE cm.user_id = ?::uuid AND cm.accepted_at IS NOT NULL
                  )
                  """,
                  type(^user_id, :string),
                  type(^user_id, :string),
                  type(^user_id, :string)
                )
              )

            _ ->
              query |> Ash.Query.filter(false)
          end

        base_query
        |> Ash.Query.filter(
          fragment(
            "search_vector @@ plainto_tsquery('simple', ?) OR similarity(name, ?) > 0.3",
            ^search_term,
            ^search_term
          )
        )
      end
    end

    create :create do
      accept [
        :name,
        :type,
        :mime_type,
        :file_size,
        :file_path,
        :metadata,
        :conversation_id,
        :folder_id,
        :workspace_id,
        :is_template,
        :uploaded_via_agent_id
      ]

      change relate_actor(:user)
      change set_attribute(:status, :pending)
      change set_attribute(:storage_backend, &Magus.Files.Storage.backend_name/0)

      # Check storage limits before creating file
      validate Magus.Files.File.Validations.CheckStorageLimits
      validate Magus.Files.File.Validations.ActorCanAccessContext
      validate Magus.Workspaces.Validations.FolderInSameWorkspace

      change run_oban_trigger(:process_file)

      # Increment storage usage after successful creation
      change after_action(fn _changeset, file, _context ->
               Magus.Files.StorageTracking.track_create(file)
               {:ok, file}
             end)

      change Magus.Files.File.Changes.BroadcastWorkspaceEvent

      change {Magus.Chat.Folder.Changes.PromoteKindForContent, content_kind: :files}
    end

    create :create_for_user do
      description "Create a file for a specific user (used by AI tools)"

      accept [
        :name,
        :type,
        :mime_type,
        :file_size,
        :file_path,
        :metadata,
        :conversation_id,
        :folder_id,
        :user_id,
        :workspace_id,
        :is_template,
        :uploaded_via_agent_id
      ]

      change set_attribute(:status, :pending)
      change set_attribute(:storage_backend, &Magus.Files.Storage.backend_name/0)
      change run_oban_trigger(:process_file)
      change Magus.Files.File.Changes.BroadcastWorkspaceEvent
    end

    update :update_status do
      accept [:status, :error_message, :chunk_count, :transient_error, :processing_attempts]
      require_atomic? false
      change Magus.Files.File.Changes.BroadcastWorkspaceEvent
    end

    update :update do
      primary? true
      description "Update user-editable file metadata (e.g. is_template flag)."
      accept [:name, :is_template]
      require_atomic? false
      change Magus.Files.File.Changes.BroadcastWorkspaceEvent
    end

    update :share_to_team do
      accept []
      require_atomic? false
      validate present(:workspace_id), message: "file must belong to a workspace"

      change {Magus.Workspaces.Changes.GrantWorkspaceAccess, resource_type: :file}
      change Magus.Files.File.Changes.BroadcastWorkspaceEvent
    end

    update :unshare_from_team do
      accept []
      require_atomic? false
      validate present(:workspace_id), message: "file must belong to a workspace"

      change {Magus.Workspaces.Changes.RevokeWorkspaceAccess, resource_type: :file}
      change Magus.Files.File.Changes.BroadcastWorkspaceEvent
    end

    update :replace_content do
      description "Replace the binary content of an existing file in storage."
      primary? false
      require_atomic? false
      accept []

      argument :binary, :binary, allow_nil?: false
      argument :request_id, :string, allow_nil?: true, default: nil

      argument :source, :atom do
        constraints one_of: [:user, :agent, :other]
        default :user
      end

      change Magus.Files.File.Changes.WriteBinary
      change Magus.Files.File.Changes.BroadcastUpdated
    end

    @doc """
    Create a file from raw content (for agent-generated files).

    Stores the content to storage and creates the file record.
    Does NOT trigger processing (no chunking for RAG).

    ## Arguments
    - `:content` - Binary content or encoded string
    - `:content_encoding` - How content is encoded: `:binary`, `:base64`, or `:data_uri`
    - `:name` - Display name for the file
    - `:type` - File type: `:document`, `:text`, `:image`, `:video`, `:email`
    - `:mime_type` - MIME type of the content
    - `:user_id` - Owner of the file
    - `:conversation_id` - Optional conversation to associate with
    """
    create :create_from_content do
      accept [:name, :type, :mime_type, :user_id, :conversation_id]

      argument :content, :binary, allow_nil?: false

      argument :content_encoding, :atom,
        default: :binary,
        constraints: [one_of: [:binary, :base64, :data_uri]]

      change set_attribute(:source, :agent)
      change Magus.Files.File.Changes.StoreContent

      # Track storage usage for agent-generated files
      change after_action(fn _changeset, file, _context ->
               Magus.Files.StorageTracking.track_create(file)
               {:ok, file}
             end)
    end

    create :create_image do
      accept [:name, :user_id, :conversation_id]

      argument :content, :binary, allow_nil?: false
      argument :mime_type, :string, default: "image/png"

      argument :content_encoding, :atom,
        default: :binary,
        constraints: [one_of: [:binary, :base64, :data_uri]]

      change set_attribute(:type, :image)
      change set_attribute(:mime_type, arg(:mime_type))
      change set_attribute(:source, :agent)
      change Magus.Files.File.Changes.StoreContent

      # Track storage usage for agent-generated files
      change after_action(fn _changeset, file, _context ->
               Magus.Files.StorageTracking.track_create(file)
               {:ok, file}
             end)
    end

    create :create_video do
      accept [:name, :user_id, :conversation_id]

      argument :content, :binary, allow_nil?: false
      argument :mime_type, :string, default: "video/mp4"

      change set_attribute(:type, :video)
      change set_attribute(:mime_type, arg(:mime_type))
      change set_attribute(:source, :agent)
      change Magus.Files.File.Changes.StoreContent

      # Track storage usage for agent-generated files
      change after_action(fn _changeset, file, _context ->
               Magus.Files.StorageTracking.track_create(file)
               {:ok, file}
             end)
    end

    create :create_video_from_url do
      accept [:name, :user_id, :conversation_id]

      argument :url, :string, allow_nil?: false
      argument :timeout, :integer, default: 300_000
      # These are set by DownloadAndStore and used by StoreContent
      argument :content, :binary, allow_nil?: true
      argument :content_encoding, :atom, default: :binary

      change set_attribute(:type, :video)
      change set_attribute(:source, :agent)
      change Magus.Files.File.Changes.DownloadAndStore
      change Magus.Files.File.Changes.StoreContent

      # Track storage usage for agent-generated files
      change after_action(fn _changeset, file, _context ->
               Magus.Files.StorageTracking.track_create(file)
               {:ok, file}
             end)
    end

    read :by_ids do
      argument :ids, {:array, :uuid}, allow_nil?: false
      filter expr(id in ^arg(:ids))
    end

    read :by_path do
      description "Look up a single file by its storage path."
      argument :file_path, :string, allow_nil?: false
      get? true
      filter expr(file_path == ^arg(:file_path))
    end

    read :images_by_ids do
      argument :ids, {:array, :uuid}, allow_nil?: false
      filter expr(id in ^arg(:ids) and type == :image)
      prepare build(limit: 1)
    end

    action :load_for_display, {:array, :map} do
      argument :ids, {:array, :uuid}, allow_nil?: false

      run Magus.Files.File.Actions.LoadForDisplay
    end

    action :load_llm_content_parts, {:array, :map} do
      argument :ids, {:array, :uuid}, allow_nil?: false

      run Magus.Files.File.Actions.LoadLlmContentParts
    end

    action :load_first_image_data_uri, :string do
      allow_nil? true
      argument :ids, {:array, :uuid}, allow_nil?: false

      run Magus.Files.File.Actions.LoadFirstImageDataUri
    end

    create :create_from_connector do
      accept [
        :name,
        :type,
        :mime_type,
        :file_size,
        :file_path,
        :metadata,
        :knowledge_collection_id,
        :external_id,
        :external_etag,
        :external_updated_at,
        :external_url
      ]

      change relate_actor(:user)
      change set_attribute(:source, :connector)
      change set_attribute(:status, :pending)
      change set_attribute(:storage_backend, &Magus.Files.Storage.backend_name/0)
      change set_attribute(:last_synced_at, &DateTime.utc_now/0)

      # Check storage limits before syncing file
      validate Magus.Files.File.Validations.CheckStorageLimits

      change run_oban_trigger(:process_file)

      # Track storage usage
      change after_action(fn _changeset, file, _context ->
               Magus.Files.StorageTracking.track_create(file)
               {:ok, file}
             end)

      change Magus.Files.File.Changes.BroadcastWorkspaceEvent
    end

    update :update_from_connector do
      description "Update a file that was synced from a connector"

      accept [
        :external_etag,
        :external_updated_at,
        :last_synced_at,
        :status,
        :file_path,
        :file_size,
        :mime_type,
        :metadata,
        :processing_attempts
      ]

      require_atomic? false

      change run_oban_trigger(:process_file)

      # Track storage delta; helper handles workspace_id changes too
      change after_action(fn changeset, file, _context ->
               Magus.Files.StorageTracking.track_update(changeset.data, file)
               {:ok, file}
             end)

      change Magus.Files.File.Changes.BroadcastWorkspaceEvent
    end

    update :soft_delete do
      accept []
      require_atomic? false
      change set_attribute(:deleted_at, &DateTime.utc_now/0)
      change Magus.Files.File.Changes.BroadcastWorkspaceEvent
      change {Magus.Workspaces.Changes.DestroyResourceGrants, resource_type: :file}
      change {Magus.Chat.Changes.UnlinkCompanions, resource_type: :file}
    end

    update :move_to_context do
      description "Move a file to a different context (global, folder, or conversation)"
      accept [:conversation_id, :folder_id]
      require_atomic? false
      validate Magus.Files.File.Validations.ActorCanAccessContext
      validate Magus.Workspaces.Validations.FolderInSameWorkspace

      # Setting both to nil makes it global
      # Setting folder_id makes it folder-scoped
      # Setting conversation_id makes it conversation-scoped
      change Magus.Files.File.Changes.BroadcastWorkspaceEvent

      change {Magus.Chat.Folder.Changes.PromoteKindForContent, content_kind: :files}
    end

    update :process do
      require_atomic? false
      transaction? false
      change Magus.Files.File.Changes.ProcessFile
      change Magus.Files.File.Changes.BroadcastWorkspaceEvent
    end

    update :reprocess do
      description "Manually or automatically re-run processing for a failed file."
      require_atomic? false
      change set_attribute(:status, :pending)
      change set_attribute(:transient_error, false)
      change set_attribute(:processing_attempts, 0)
      change run_oban_trigger(:process_file)
    end

    update :recover_stuck_processing do
      description """
      Resets a file stuck in :processing (e.g. crashed between the chunk
      destroy and insert steps of ProcessFile, see process_file.ex) back to
      :pending so the :process_file trigger picks it up again. Run by the
      recover_stuck_processing Oban trigger; bounded by processing_attempts < 4.
      """

      require_atomic? false
      change set_attribute(:status, :pending)
      change set_attribute(:transient_error, false)

      change fn changeset, _context ->
        attempts = changeset.data.processing_attempts || 0
        Ash.Changeset.force_change_attribute(changeset, :processing_attempts, attempts + 1)
      end

      change run_oban_trigger(:process_file)
    end
  end

  policies do
    import Magus.Workspaces.Policies

    # AshOban triggers bypass authorization completely
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # AI Agent can create files (for generated images, videos, etc.)
    bypass Magus.Checks.IsAiAgent do
      authorize_if always()
    end

    # Fulltext search handles its own authorization in the prepare to avoid
    # column ambiguity issues when joining with conversations table
    bypass action(:fulltext_search) do
      authorize_if always()
    end

    # Generic actions for loading file display data
    # These are called with IDs from message content that users have already been authorized to see
    policy action(:load_for_display) do
      authorize_if actor_present()
    end

    policy action(:load_llm_content_parts) do
      authorize_if actor_present()
    end

    policy action(:load_first_image_data_uri) do
      authorize_if actor_present()
    end

    policy action(:create_for_user) do
      authorize_if Magus.Checks.IsAiAgent
    end

    policy action([:create_from_content, :create_image, :create_video, :create_video_from_url]) do
      authorize_if Magus.Checks.IsAiAgent
    end

    policy action(:create_from_connector) do
      authorize_if Magus.Files.File.Checks.ActorCanCreateConnectorFile
    end

    # Generic workspace-scoped policies: creator ownership, workspace-admin
    # management, and per-grantee access via resource_accesses. Extras preserve
    # conversation/knowledge-source read paths that predate the grants model.
    workspace_scoped_policies(
      resource_type: :file,
      extra_read: [
        quote do
          authorize_if expr(
                         not is_nil(conversation_id) and
                           conversation.user_id == ^actor(:id)
                       )
        end,
        quote do
          authorize_if expr(
                         not is_nil(conversation_id) and
                           exists(
                             conversation.members,
                             user_id == ^actor(:id) and not is_nil(accepted_at)
                           )
                       )
        end,
        quote do
          authorize_if expr(
                         not is_nil(knowledge_collection_id) and
                           knowledge_collection.knowledge_source.user_id == ^actor(:id)
                       )
        end,
        quote do
          authorize_if expr(
                         not is_nil(knowledge_collection_id) and
                           not is_nil(knowledge_collection.knowledge_source.workspace_id) and
                           exists(
                             knowledge_collection.knowledge_source.workspace.members,
                             is_active == true and user_id == ^actor(:id)
                           )
                       )
        end
      ],
      extra_update: [
        quote do
          authorize_if Magus.Files.File.Checks.ActorManagesFile
        end
      ],
      extra_destroy: [
        quote do
          authorize_if Magus.Files.File.Checks.ActorManagesFile
        end
      ]
    )
  end

  pub_sub do
    module MagusWeb.Endpoint
    prefix "files"

    publish_all :create, ["files", :user_id]
    publish_all :update, ["files", :user_id]
    publish_all :destroy, ["files", :user_id]

    # Workspace-scoped broadcasts use topic "workspaces:{workspace_id}:files" to match
    # the Prompt ("workspaces:{id}:prompts") and CustomAgent ("workspaces:{id}:agents")
    # conventions. Because Ash PubSub has no per-declaration prefix override, those
    # broadcasts are emitted directly via BroadcastWorkspaceEvent change modules on
    # each action rather than from this block.
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :type, :atom do
      constraints one_of: [:document, :text, :image, :video, :email]
      allow_nil? false
      public? true
    end

    attribute :source, :atom do
      constraints one_of: [:user, :agent, :connector]
      allow_nil? false
      default :user
      public? true

      description "Whether file was uploaded by user, generated by agent, or synced from connector"
    end

    attribute :mime_type, :string do
      allow_nil? false
      public? true
    end

    attribute :file_size, :integer do
      allow_nil? false
      public? true
    end

    attribute :file_path, :string do
      allow_nil? false
      # Selectable so the SPA can build /uploads/files/<path> preview URLs;
      # the serve controller re-authorizes every request.
      public? true
    end

    attribute :storage_backend, :string do
      allow_nil? false
      # Static DB fallback only; every create action stamps the configured
      # backend via &Magus.Files.Storage.backend_name/0 (see actions above).
      default "local"
    end

    attribute :status, :atom do
      constraints one_of: [:pending, :processing, :ready, :error]
      allow_nil? false
      default :pending
      public? true
    end

    attribute :error_message, :string do
      public? true
    end

    attribute :metadata, :map do
      default %{}
    end

    attribute :chunk_count, :integer do
      default 0
      public? true
    end

    attribute :processing_attempts, :integer do
      allow_nil? false
      default 0
      public? false
      description "Transient processing failures so far; bounds the automatic retry cron."
    end

    attribute :transient_error, :boolean do
      allow_nil? false
      default false
      public? false

      description "Last processing failure was transient (storage/embedding); eligible for auto-retry."
    end

    attribute :external_id, :string do
      public? true
    end

    attribute :external_etag, :string do
      public? true
    end

    attribute :external_updated_at, :utc_datetime_usec do
      public? true
    end

    attribute :external_url, :string do
      public? true
    end

    attribute :last_synced_at, :utc_datetime_usec do
      public? true
    end

    attribute :deleted_at, :utc_datetime_usec do
      public? true
    end

    attribute :is_template, :boolean do
      allow_nil? false
      default false
      public? true

      description "When true, this file is a workspace template, discoverable by agents and surfaced in the Templates filter of the Files browser."
    end

    attribute :uploaded_via_agent_id, :uuid do
      allow_nil? true
      public? true
      description "Set when this file was uploaded directly through a custom agent's settings."
    end

    timestamps public?: true
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      allow_nil? false
      public? true
    end

    belongs_to :conversation, Magus.Chat.Conversation do
      allow_nil? true
      public? true
    end

    belongs_to :folder, Magus.Chat.Folder do
      allow_nil? true
      public? true
    end

    belongs_to :workspace, Magus.Workspaces.Workspace do
      allow_nil? true
      public? true
    end

    belongs_to :knowledge_collection, Magus.Knowledge.KnowledgeCollection do
      allow_nil? true
      public? true
    end

    belongs_to :uploaded_via_agent, Magus.Agents.CustomAgent do
      source_attribute :uploaded_via_agent_id
      destination_attribute :id
      define_attribute? false
      attribute_writable? true
      public? true
    end

    has_many :chunks, Magus.Files.Chunk
  end

  calculations do
    import Magus.Workspaces.Calculations

    calculate :llm_content_part, :map do
      description "LLM-compatible content part (image or text attachment)"
      calculation Magus.Files.File.Calculations.LlmContentPart
    end

    calculate :data_uri, :string do
      description "Data URI representation (for images)"
      calculation Magus.Files.File.Calculations.DataUri
    end

    calculate :display_info, :map do
      description "Display-ready map with id, type, name, url, mime_type, size"
      calculation Magus.Files.File.Calculations.DisplayInfo
    end

    is_shared_to_workspace(:file)
  end

  identities do
    identity :unique_collection_external, [:knowledge_collection_id, :external_id],
      where: expr(not is_nil(knowledge_collection_id))
  end
end
