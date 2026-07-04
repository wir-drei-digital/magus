defmodule Magus.Knowledge.KnowledgeCollection do
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Knowledge,
    extensions: [AshOban, AshTypescript.Resource],
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  oban do
    triggers do
      trigger :full_sync do
        action :do_full_sync
        queue :knowledge_sync
        scheduler_cron false
        worker_module_name __MODULE__.Workers.FullSync
        scheduler_module_name __MODULE__.Schedulers.FullSync
      end

      trigger :incremental_sync do
        action :incremental_sync
        queue :knowledge_sync
        scheduler_cron "0 * * * *"
        read_action :read
        worker_module_name __MODULE__.Workers.IncrementalSync
        scheduler_module_name __MODULE__.Schedulers.IncrementalSync

        where expr(
                sync_status != :pending and sync_strategy != :manual and
                  knowledge_source.needs_reauth == false
              )
      end
    end
  end

  typescript do
    type_name "KnowledgeCollection"
  end

  postgres do
    table "knowledge_collections"
    repo Magus.Repo

    references do
      reference :workspace, on_delete: :delete
    end
  end

  actions do
    defaults [:read]

    destroy :destroy do
      primary? true
      require_atomic? false
      change Magus.Knowledge.KnowledgeCollection.Changes.CleanupFiles

      change {Magus.Workspaces.Changes.DestroyResourceGrants,
              resource_type: :knowledge_collection}
    end

    create :create do
      accept [
        :name,
        :external_id,
        :external_path,
        :sync_strategy,
        :sync_interval_minutes,
        :settings
      ]

      argument :knowledge_source_id, :uuid do
        allow_nil? false
      end

      change manage_relationship(:knowledge_source_id, :knowledge_source, type: :append)
      change set_attribute(:sync_status, :pending)
      change Magus.Knowledge.KnowledgeCollection.Changes.GrantDefaultAgentAccess

      change fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _cs, coll ->
          source =
            Ash.get!(Magus.Knowledge.KnowledgeSource, coll.knowledge_source_id, authorize?: false)

          if source.workspace_id do
            {:ok,
             Ash.update!(coll, %{workspace_id: source.workspace_id},
               action: :set_workspace,
               authorize?: false
             )}
          else
            {:ok, coll}
          end
        end)
      end
    end

    update :set_workspace do
      accept [:workspace_id]
      require_atomic? false
    end

    update :update_sync_status do
      accept [
        :sync_status,
        :last_synced_at,
        :content_updated_at,
        :sync_cursor,
        :item_count,
        :error_count,
        :last_error,
        :sync_log
      ]

      require_atomic? false
    end

    update :full_sync do
      require_atomic? false
      change set_attribute(:sync_status, :syncing)
      change run_oban_trigger(:full_sync)
    end

    update :do_full_sync do
      require_atomic? false
      change Magus.Knowledge.KnowledgeCollection.Changes.FullSync
    end

    update :incremental_sync do
      require_atomic? false
      change Magus.Knowledge.KnowledgeCollection.Changes.IncrementalSync
    end

    read :for_source do
      argument :knowledge_source_id, :uuid, allow_nil?: false
      filter expr(knowledge_source_id == ^arg(:knowledge_source_id))
    end

    read :personal_collections do
      description "User-owned collections with no workspace_id."
      filter expr(is_nil(workspace_id))
      prepare build(sort: [name: :asc])
    end

    read :list_for_workspace do
      description "Collections scoped to a workspace."
      argument :workspace_id, :uuid, allow_nil?: false
      filter expr(workspace_id == ^arg(:workspace_id))
      prepare build(load: [:is_shared_to_workspace], sort: [name: :asc])
    end
  end

  policies do
    import Magus.Workspaces.Policies

    # AshOban triggers bypass authorization completely
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    workspace_scoped_policies(
      resource_type: :knowledge_collection,
      owner_expr:
        quote do
          Ash.Expr.expr(knowledge_source.user_id == ^actor(:id))
        end,
      extra_create: [
        quote do
          authorize_if Magus.Knowledge.KnowledgeCollection.Checks.ActorCanAccessSource
        end
      ]
    )
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :external_id, :string do
      allow_nil? false
      public? true
      description "Provider-side identifier (folder ID, database ID, etc.)"
    end

    attribute :external_path, :string do
      public? true
      description "Human-readable path within the provider"
    end

    attribute :sync_status, :atom do
      constraints one_of: [:pending, :syncing, :synced, :error, :disabled]
      allow_nil? false
      default :pending
      public? true
    end

    attribute :sync_strategy, :atom do
      constraints one_of: [:poll, :webhook, :manual]
      allow_nil? false
      default :poll
      public? true
    end

    attribute :sync_interval_minutes, :integer do
      default 60
      public? true
    end

    attribute :last_synced_at, :utc_datetime_usec do
      public? true
    end

    attribute :content_updated_at, :utc_datetime_usec do
      public? true
    end

    attribute :sync_cursor, :map do
      default %{}
      public? true
      description "Opaque cursor for incremental sync (provider-specific)"
    end

    attribute :item_count, :integer do
      default 0
      public? true
    end

    attribute :error_count, :integer do
      default 0
      public? true
    end

    attribute :last_error, :string do
      public? true
    end

    attribute :settings, :map do
      default %{}
      public? true
      description "Collection-specific settings (filters, include/exclude patterns, etc.)"
    end

    attribute :sync_log, {:array, :map} do
      default []
      public? true

      description "Log entries from sync operations. Each entry: %{t: timestamp, l: level, m: message}"
    end

    timestamps()
  end

  relationships do
    belongs_to :knowledge_source, Magus.Knowledge.KnowledgeSource do
      allow_nil? false
    end

    belongs_to :workspace, Magus.Workspaces.Workspace do
      public? true
      allow_nil? true
    end
  end

  calculations do
    import Magus.Workspaces.Calculations

    is_shared_to_workspace(:knowledge_collection)
  end

  identities do
    identity :unique_external, [:knowledge_source_id, :external_id]
  end
end
