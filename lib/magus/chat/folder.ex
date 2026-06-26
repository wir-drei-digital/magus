defmodule Magus.Chat.Folder do
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Chat,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub],
    extensions: [AshTypescript.Resource]

  postgres do
    table "folders"
    repo Magus.Repo

    references do
      reference :parent, on_delete: :nilify
      reference :user, on_delete: :delete
      reference :workspace, on_delete: :delete
    end
  end

  typescript do
    type_name "Folder"
  end

  actions do
    read :read do
      primary? true
    end

    create :create do
      accept [:name, :parent_id, :position, :workspace_id, :kind]
      change relate_actor(:user)

      validate {Magus.Chat.Folder.Validations.ActorOwnsFolderField, field: :parent_id}

      validate {Magus.Workspaces.Validations.ParentInSameWorkspace,
                parent_field: :parent_id,
                workspace_field: :workspace_id,
                parent_resource: __MODULE__}
    end

    update :update do
      accept [:name, :position]
    end

    update :move_to_folder do
      accept [:parent_id]
      require_atomic? false

      validate {Magus.Chat.Folder.Validations.ActorOwnsFolderField, field: :parent_id}

      validate {Magus.Workspaces.Validations.ParentInSameWorkspace,
                parent_field: :parent_id,
                workspace_field: :workspace_id,
                parent_resource: __MODULE__}

      change {Magus.Chat.Folder.Changes.SyncWorkspaceShareWithFolder,
              container_field: :parent_id,
              share_action: :share_to_team,
              unshare_action: :unshare_from_team}
    end

    update :promote_to_mixed do
      description "Internal: silently promote a folder's kind to :mixed when cross-kind content is added. Used by Magus.Chat.Folder.Changes.PromoteKindForContent."
      accept []
      require_atomic? false
      change set_attribute(:kind, :mixed)
    end

    update :share_to_team do
      accept []
      require_atomic? false
      validate present(:workspace_id), message: "folder must belong to a workspace"

      change {Magus.Workspaces.Changes.GrantWorkspaceAccess, resource_type: :folder}
      change Magus.Chat.Folder.Changes.CascadeShareToChildren
    end

    update :unshare_from_team do
      accept []
      require_atomic? false
      validate present(:workspace_id), message: "folder must belong to a workspace"

      change {Magus.Workspaces.Changes.RevokeWorkspaceAccess, resource_type: :folder}
      change Magus.Chat.Folder.Changes.CascadeUnshareFromChildren
    end

    destroy :destroy do
      primary? true
      require_atomic? false

      change {Magus.Workspaces.Changes.DestroyResourceGrants, resource_type: :folder}
    end

    read :my_folders do
      argument :kinds, {:array, :atom},
        constraints: [items: [one_of: [:files, :conversations, :mixed]]],
        allow_nil?: true,
        default: nil

      filter expr(
               user_id == ^actor(:id) and is_nil(workspace_id) and
                 (is_nil(^arg(:kinds)) or kind in ^arg(:kinds))
             )
    end

    read :workspace_folders do
      argument :workspace_id, :uuid, allow_nil?: false

      argument :kinds, {:array, :atom},
        constraints: [items: [one_of: [:files, :conversations, :mixed]]],
        allow_nil?: true,
        default: nil

      filter expr(
               workspace_id == ^arg(:workspace_id) and
                 (is_nil(^arg(:kinds)) or kind in ^arg(:kinds))
             )
    end

    read :list_for_workspace do
      description "Folders scoped to a workspace (read authorization governed by policies)."
      argument :workspace_id, :uuid, allow_nil?: false

      argument :kinds, {:array, :atom},
        constraints: [items: [one_of: [:files, :conversations, :mixed]]],
        allow_nil?: true,
        default: nil

      filter expr(
               workspace_id == ^arg(:workspace_id) and
                 (is_nil(^arg(:kinds)) or kind in ^arg(:kinds))
             )

      prepare build(load: [:is_shared_to_workspace], sort: [position: :asc, inserted_at: :asc])
    end

    read :root_folders do
      filter expr(user_id == ^actor(:id) and is_nil(parent_id) and is_nil(workspace_id))
    end

    read :list_in_folder do
      description "Direct sub-folders of a parent folder."
      argument :parent_id, :uuid, allow_nil?: false

      argument :kinds, {:array, :atom},
        constraints: [items: [one_of: [:files, :conversations, :mixed]]],
        allow_nil?: true,
        default: nil

      filter expr(
               parent_id == ^arg(:parent_id) and
                 (is_nil(^arg(:kinds)) or kind in ^arg(:kinds))
             )

      prepare build(sort: [name: :asc])
    end
  end

  policies do
    import Magus.Workspaces.Policies

    workspace_scoped_policies(resource_type: :folder)
  end

  pub_sub do
    module MagusWeb.Endpoint
    prefix "chat"

    publish_all :create, ["folders", :user_id] do
      transform & &1.data
    end

    publish_all :update, ["folders", :user_id] do
      transform & &1.data
    end

    publish_all :destroy, ["folders", :user_id] do
      event "destroy"
      transform & &1.data
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1
    end

    attribute :position, :integer do
      default 0
      public? true
    end

    attribute :kind, :atom do
      allow_nil? false
      default :conversations
      public? true
      constraints one_of: [:files, :conversations, :mixed]
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      public? true
      allow_nil? false
    end

    belongs_to :workspace, Magus.Workspaces.Workspace do
      public? true
      allow_nil? true
    end

    belongs_to :parent, __MODULE__ do
      public? true
      allow_nil? true
    end

    has_many :children, __MODULE__ do
      destination_attribute :parent_id
      public? true
    end

    has_many :conversations, Magus.Chat.Conversation do
      public? true
    end
  end

  calculations do
    import Magus.Workspaces.Calculations

    is_shared_to_workspace(:folder)
  end
end
