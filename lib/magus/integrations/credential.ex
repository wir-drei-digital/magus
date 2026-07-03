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
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban]

  postgres do
    table "integration_credentials"
    repo Magus.Repo

    identity_wheres_to_sql key_hash: "key_hash IS NOT NULL"
  end

  oban do
    triggers do
      trigger :warn_expiring do
        action :process_expiry_warning
        queue :credential_expiry
        scheduler_cron "0 6 * * *"
        read_action :expiring_soon
        worker_read_action :expiring_soon
        where expr(is_expiring_or_expired)
        worker_module_name Magus.Integrations.Credential.Workers.WarnExpiring
        scheduler_module_name Magus.Integrations.Credential.Schedulers.WarnExpiring
        max_attempts 1
      end
    end
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

    read :expiring_soon do
      description """
      Credentials that are either already expired, or expiring within 7
      days and not yet warned about. Backs the daily `:warn_expiring`
      trigger. `expiry_warned_at` is the de-dupe key for the not-yet-expired
      branch: `:refresh_token` clears it whenever `expires_at` changes, so a
      re-issued token gets a fresh warning window. Already-expired
      credentials are always included (no de-dupe attribute needed — the
      change module's handler is idempotent via the linked integration's
      `:error` status).
      """

      pagination keyset?: true, required?: false
      filter expr(is_expiring_or_expired)
    end

    create :create do
      accept [:credential_type, :encrypted_data, :expires_at, :user_integration_id, :key_hash]
    end

    update :refresh_token do
      accept [:encrypted_data, :expires_at, :key_hash]

      # A new/rotated expiry supersedes any prior warning: reset so the
      # credential can be re-evaluated (and re-warned) against its new
      # expires_at.
      change set_attribute(:expiry_warned_at, nil)
    end

    update :mark_expiry_warned do
      description "Oban-triggered: stamps expiry_warned_at for a soon-to-expire credential"
      accept []
      change set_attribute(:expiry_warned_at, &DateTime.utc_now/0)
    end

    update :process_expiry_warning do
      description "Oban-triggered dispatch for the daily credential-expiry sweep"
      accept []
      require_atomic? false
      transaction? false

      change Magus.Integrations.Credential.Changes.ProcessExpiryWarning
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

    attribute :expiry_warned_at, :utc_datetime_usec do
      description """
      When the owner was last warned about this credential's upcoming
      expiry. Cleared by :refresh_token whenever expires_at changes, so a
      re-issued token is re-evaluated against its own 7-day window.
      """
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user_integration, Magus.Integrations.UserIntegration do
      allow_nil? false
    end
  end

  calculations do
    calculate :is_expiring_or_expired, :boolean do
      public? false

      calculation expr(
                    not is_nil(expires_at) and
                      (expires_at < now() or
                         (expires_at < from_now(7, :day) and is_nil(expiry_warned_at)))
                  )
    end
  end

  identities do
    identity :key_hash, [:key_hash], where: expr(not is_nil(key_hash))
  end

  # No policies - access is controlled by limiting code interface exposure
  # and using authorize?: false for all internal operations
end
