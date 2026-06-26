defmodule Magus.Chat.UserFolderState do
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Chat,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshTypescript.Resource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "user_folder_states"
    repo Magus.Repo

    references do
      reference :user, on_delete: :delete
      reference :folder, on_delete: :delete
    end
  end

  typescript do
    type_name "UserFolderState"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:folder_id, :is_expanded]
      change relate_actor(:user)

      validate {Magus.Chat.Folder.Validations.ActorOwnsFolderField, required?: true}
    end

    update :update do
      accept [:is_expanded]
    end

    create :upsert do
      accept [:folder_id, :is_expanded]
      change relate_actor(:user)
      upsert? true
      upsert_identity :unique_user_folder
      upsert_fields [:is_expanded]

      validate {Magus.Chat.Folder.Validations.ActorOwnsFolderField, required?: true}
    end

    read :my_folder_states do
      filter expr(user_id == ^actor(:id))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:update, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :is_expanded, :boolean do
      default false
      allow_nil? false
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      public? true
      allow_nil? false
    end

    belongs_to :folder, Magus.Chat.Folder do
      public? true
      allow_nil? false
    end
  end

  identities do
    identity :unique_user_folder, [:user_id, :folder_id]
  end
end
