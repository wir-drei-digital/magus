defmodule Magus.Knowledge.KnowledgeSource do
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Knowledge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "knowledge_sources"
    repo Magus.Repo
  end

  typescript do
    type_name "KnowledgeSource"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:name, :provider, :auth_config, :settings, :workspace_id]

      change relate_actor(:user)
      change set_attribute(:status, :pending)
    end

    update :update_status do
      accept [:status, :last_error]
      require_atomic? false

      change fn changeset, _context ->
        if Ash.Changeset.get_attribute(changeset, :status) == :active do
          Ash.Changeset.force_change_attribute(changeset, :connected_at, DateTime.utc_now())
        else
          changeset
        end
      end
    end

    update :update_auth_config do
      accept [:auth_config]
      require_atomic? false
    end

    read :for_user do
      filter expr(user_id == ^actor(:id))
    end

    read :for_workspace do
      argument :workspace_id, :uuid, allow_nil?: false
      filter expr(workspace_id == ^arg(:workspace_id))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:user)

      authorize_if expr(
                     not is_nil(workspace_id) and
                       exists(workspace.members, is_active == true and user_id == ^actor(:id))
                   )
    end

    policy action_type(:create) do
      authorize_if {Magus.Checks.ActorIsActiveWorkspaceMember, allow_nil?: true}
    end

    policy action_type([:update, :destroy]) do
      authorize_if Magus.Checks.ActorCanManageWorkspaceResource
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :provider, :atom do
      constraints one_of: [
                    :google_drive,
                    :onedrive,
                    :nextcloud,
                    :notion,
                    :confluence,
                    :github,
                    :gitlab,
                    :affine,
                    :obsidian,
                    :web
                  ]

      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:pending, :active, :error, :disabled]
      allow_nil? false
      default :pending
      public? true
    end

    attribute :auth_config, Magus.Integrations.EncryptedMap do
      allow_nil? false
      public? false
      description "Encrypted OAuth tokens, API keys, base URLs"
    end

    attribute :settings, :map do
      default %{}
      public? true
      description "Provider-specific config: domain, org, etc."
    end

    attribute :last_error, :string do
      public? true
    end

    attribute :connected_at, :utc_datetime_usec do
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      allow_nil? false
    end

    belongs_to :workspace, Magus.Workspaces.Workspace do
      allow_nil? true
      public? true
    end

    has_many :collections, Magus.Knowledge.KnowledgeCollection
  end
end
