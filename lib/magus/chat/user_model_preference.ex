defmodule Magus.Chat.UserModelPreference do
  @moduledoc """
  Per-user curation of the model catalog: favorite, hide, and order models.
  One row per (user, model). Absence means default (not favorite, not hidden,
  unordered). In the picker, hidden wins over favorite.
  """
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Chat,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "user_model_preferences"
    repo Magus.Repo

    references do
      reference :user, on_delete: :delete
      reference :model, on_delete: :delete
    end
  end

  typescript do
    type_name "UserModelPreference"
    field_names favorite?: "favorite", hidden?: "hidden"
  end

  actions do
    defaults [:read, :destroy]

    read :my_model_preferences do
      filter expr(user_id == ^actor(:id))
    end

    create :set_favorite do
      accept [:model_id, :favorite?]
      change relate_actor(:user)
      upsert? true
      upsert_identity :unique_user_model
      upsert_fields [:favorite?]
      validate {Magus.Chat.UserModelPreference.Validations.ModelSelectable, []}
    end

    create :set_hidden do
      accept [:model_id, :hidden?]
      change relate_actor(:user)
      upsert? true
      upsert_identity :unique_user_model
      upsert_fields [:hidden?]
      validate {Magus.Chat.UserModelPreference.Validations.ModelSelectable, []}
    end

    create :set_position do
      accept [:model_id, :position]
      change relate_actor(:user)
      upsert? true
      upsert_identity :unique_user_model
      upsert_fields [:position]
      validate {Magus.Chat.UserModelPreference.Validations.ModelSelectable, []}
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type(:destroy) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :favorite?, :boolean do
      default false
      allow_nil? false
      public? true
    end

    attribute :hidden?, :boolean do
      default false
      allow_nil? false
      public? true
    end

    attribute :position, :integer do
      allow_nil? true
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      allow_nil? false
    end

    belongs_to :model, Magus.Chat.Model do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_user_model, [:user_id, :model_id]
  end
end
