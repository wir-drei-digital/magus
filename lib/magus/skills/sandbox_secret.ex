defmodule Magus.Skills.SandboxSecret do
  @moduledoc """
  Per-user sandbox secrets vault. Keys are stored once per user; a skill
  receives only the keys it declares in `required_secrets`, injected into
  /workspace/.env at materialization. Values are encrypted at rest (Cloak
  AES-256-GCM) via the shared EncryptedString type.
  """
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Skills,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "sandbox_secrets"
    repo Magus.Repo

    references do
      reference :user, on_delete: :delete
    end
  end

  typescript do
    type_name "SandboxSecret"
  end

  actions do
    defaults [:read, :destroy]

    read :my_secrets do
      filter expr(user_id == ^actor(:id))
    end

    read :for_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end

    create :create do
      accept [:key, :value, :description]
      change relate_actor(:user)

      validate match(:key, ~r/^[A-Za-z_][A-Za-z0-9_]*$/),
        message: "must be a valid environment variable name"
    end

    update :update do
      accept [:value, :description]
    end
  end

  policies do
    policy action_type([:read, :update, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end

    policy action(:create) do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :key, :string, allow_nil?: false, public?: true

    attribute :value, Magus.Agents.AgentSecret.EncryptedString do
      allow_nil? false
      # NOT public: the plaintext is never sent to the client. The settings UI
      # is write-only.
    end

    attribute :description, :string, allow_nil?: true, public?: true

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Magus.Accounts.User, allow_nil?: false
  end

  identities do
    identity :unique_key_per_user, [:user_id, :key]
  end
end
