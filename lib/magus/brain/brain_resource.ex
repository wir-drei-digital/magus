defmodule Magus.Brain.BrainResource do
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Brain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "brains"
    repo Magus.Repo

    references do
      reference :user, on_delete: :delete
      reference :workspace, on_delete: :delete
    end
  end

  typescript do
    type_name "Brain"
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:title, :description, :icon, :color, :workspace_id]

      change set_attribute(:user_id, actor(:id))
      change {Magus.Brain.Changes.Slugify, attribute: :title, target: :slug}
    end

    update :update do
      primary? true
      accept [:title, :description, :icon, :color]
    end

    update :share_to_team do
      accept []
      require_atomic? false
      validate present(:workspace_id), message: "brain must belong to a workspace"

      change {Magus.Workspaces.Changes.GrantWorkspaceAccess, resource_type: :brain}
    end

    update :unshare_from_team do
      accept []
      require_atomic? false
      validate present(:workspace_id), message: "brain must belong to a workspace"

      change {Magus.Workspaces.Changes.RevokeWorkspaceAccess, resource_type: :brain}
    end

    update :archive do
      accept []
      change set_attribute(:is_archived, true)
    end

    destroy :destroy do
      primary? true
      require_atomic? false

      change {Magus.Workspaces.Changes.DestroyResourceGrants, resource_type: :brain}
    end

    read :list_for_user do
      filter expr(user_id == ^actor(:id) and is_archived == false and is_nil(workspace_id))
      prepare build(sort: [updated_at: :desc])
    end

    read :list_for_workspace do
      description "List brains scoped to a workspace (read authorization governed by policies)"
      argument :workspace_id, :uuid, allow_nil?: false
      filter expr(workspace_id == ^arg(:workspace_id) and is_archived == false)
      prepare build(load: [:is_shared_to_workspace], sort: [updated_at: :desc])
    end
  end

  policies do
    import Magus.Workspaces.Policies

    workspace_scoped_policies(resource_type: :brain)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :title, :string, allow_nil?: false, public?: true
    attribute :description, :string, public?: true
    attribute :slug, :string, allow_nil?: false
    attribute :icon, :string, public?: true
    attribute :color, :string, public?: true
    attribute :is_archived, :boolean, default: false

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Magus.Accounts.User, allow_nil?: false

    belongs_to :workspace, Magus.Workspaces.Workspace do
      public? true
      allow_nil? true
    end

    has_many :pages, Magus.Brain.Page do
      destination_attribute :brain_id
    end
  end

  calculations do
    import Magus.Workspaces.Calculations

    is_shared_to_workspace(:brain)
  end

  identities do
    identity :unique_slug_per_user, [:user_id, :slug]
  end
end
