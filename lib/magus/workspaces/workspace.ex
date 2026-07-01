defmodule Magus.Workspaces.Workspace do
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Workspaces,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshPaperTrail.Resource, AshTypescript.Resource]

  postgres do
    table "workspaces"
    repo Magus.Repo

    references do
      reference :default_agent, on_delete: :nilify
    end
  end

  paper_trail do
    primary_key_type :uuid_v7
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [:inserted_at, :updated_at, :storage_usage_bytes]
    belongs_to_actor :user, Magus.Accounts.User, domain: Magus.Accounts
  end

  typescript do
    type_name "Workspace"
  end

  actions do
    defaults [:read]

    create :create do
      accept [:name, :slug]

      change Magus.Workspaces.Workspace.Changes.CreateOwnerMember
      change Magus.Workspaces.Workspace.Changes.CreateDefaultAgent
    end

    update :update do
      accept [:name, :allowed_model_ids, :default_agent_id, :is_active]
    end

    update :admin_update do
      accept [:name, :is_active]
      require_atomic? false
    end

    update :deactivate do
      accept []
      require_atomic? false
      description "Soft-delete: deactivates workspace, unwinds members and child resources"

      change set_attribute(:is_active, false)
      change Magus.Workspaces.Workspace.Changes.SoftDeleteWorkspace
    end

    update :increment_storage do
      argument :bytes, :integer, allow_nil?: false

      change atomic_update(:storage_usage_bytes, expr(storage_usage_bytes + ^arg(:bytes)))
    end

    update :decrement_storage do
      argument :bytes, :integer, allow_nil?: false

      change atomic_update(
               :storage_usage_bytes,
               expr(fragment("GREATEST(0, ? - ?)", storage_usage_bytes, ^arg(:bytes)))
             )
    end

    update :recalculate_storage do
      accept []
      require_atomic? false
      change Magus.Workspaces.Workspace.Changes.RecalculateStorageUsage
    end

    update :set_organization do
      accept [:organization_id]
      require_atomic? false
    end

    read :all_workspaces do
      prepare build(sort: [inserted_at: :desc], load: [:members])
    end

    read :my_workspaces do
      filter expr(exists(members, is_active == true and user_id == ^actor(:id)))
    end

    action :member_usage, {:array, :map} do
      description "Per-active-member credit/storage/last-active breakdown (admin usage view)."
      argument :workspace_id, :uuid, allow_nil?: false

      run fn input, ctx ->
        Magus.Workspaces.MemberUsage.for_workspace(input.arguments.workspace_id, actor: ctx.actor)
      end
    end
  end

  policies do
    bypass action([
             :admin_update,
             :all_workspaces,
             :increment_storage,
             :decrement_storage,
             :recalculate_storage
           ]) do
      authorize_if always()
    end

    bypass action(:set_organization) do
      authorize_if always()
    end

    policy action(:deactivate) do
      authorize_if Magus.Checks.IsAdmin

      authorize_if expr(
                     exists(
                       members,
                       is_active == true and role == :admin and user_id == ^actor(:id)
                     )
                   )
    end

    policy action(:create) do
      authorize_if actor_present()
    end

    policy action(:my_workspaces) do
      authorize_if actor_present()
    end

    # The action's run path loads the workspace under the actor (:read requires
    # membership) and then narrows to active admins, so actor_present suffices.
    policy action(:member_usage) do
      authorize_if actor_present()
    end

    policy action(:read) do
      authorize_if expr(exists(members, is_active == true and user_id == ^actor(:id)))
    end

    policy action_type([:update, :destroy]) do
      authorize_if expr(
                     exists(
                       members,
                       is_active == true and role == :admin and user_id == ^actor(:id)
                     )
                   )
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
      constraints match: ~r/\A[a-z0-9][a-z0-9-]*[a-z0-9]\z/, min_length: 2, max_length: 64
    end

    attribute :allowed_model_ids, {:array, :uuid} do
      allow_nil? true
      public? true
    end

    attribute :is_active, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :storage_usage_bytes, :integer do
      allow_nil? false
      default 0
      public? true
      description "Cached storage usage in bytes, updated on file create/delete"
    end

    attribute :organization_id, :uuid do
      allow_nil? true
      public? true
      description "Owning organization (nil = personal/individual workspace)."
    end

    timestamps()
  end

  relationships do
    belongs_to :default_agent, Magus.Agents.CustomAgent do
      allow_nil? true
      public? true
    end

    has_many :members, Magus.Workspaces.WorkspaceMember do
      public? true
    end

    belongs_to :organization, Magus.Organizations.Organization do
      define_attribute? false
      allow_nil? true
      public? true
    end
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
