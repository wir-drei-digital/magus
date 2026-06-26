defmodule Magus.Integrations.Credential do
  @moduledoc """
  Stores encrypted credentials for integrations.

  SECURITY: Read access is restricted to internal system operations
  (reactors, controllers) via `authorize?: false`. This resource has
  no policies — access control is enforced by only exposing the
  `get_credential_for_integration` code interface for internal use.

  All credential access is logged to AuditLog for security auditing.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Integrations,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "integration_credentials"
    repo Magus.Repo

    identity_wheres_to_sql key_hash: "key_hash IS NOT NULL"
  end

  # SECURITY: Read actions are internal only - accessed via authorize?: false
  actions do
    read :internal_read do
      primary? true
    end

    read :for_integration do
      argument :user_integration_id, :uuid, allow_nil?: false
      filter expr(user_integration_id == ^arg(:user_integration_id))
      get? true
    end

    read :by_key_hash do
      argument :key_hash, :string, allow_nil?: false
      get? true
      filter expr(key_hash == ^arg(:key_hash))
      prepare build(load: [:user_integration])
    end

    create :create do
      accept [:credential_type, :encrypted_data, :expires_at, :user_integration_id, :key_hash]
    end

    update :refresh_token do
      accept [:encrypted_data, :expires_at, :key_hash]
    end

    destroy :destroy do
      primary? true
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :key_hash, :string do
      public? true
      allow_nil? true
      description "SHA-256 hash of the API key for indexed lookups"
    end

    attribute :credential_type, :atom do
      allow_nil? false
      constraints one_of: [:oauth2, :api_key, :imap]
      description "Type of credential: :oauth2 | :api_key | :imap"
    end

    attribute :encrypted_data, Magus.Integrations.EncryptedMap do
      allow_nil? false
      description "Encrypted credential data (access_token, api_key, etc.)"
    end

    attribute :expires_at, :utc_datetime_usec do
      description "When the credential expires (for OAuth tokens)"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user_integration, Magus.Integrations.UserIntegration do
      allow_nil? false
    end
  end

  identities do
    identity :key_hash, [:key_hash], where: expr(not is_nil(key_hash))
  end

  # No policies - access is controlled by limiting code interface exposure
  # and using authorize?: false for all internal operations
end
