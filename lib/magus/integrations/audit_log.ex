defmodule Magus.Integrations.AuditLog do
  @moduledoc """
  Security audit trail for integration operations.

  Records all credential access, webhook attempts, and API operations
  for security monitoring and debugging.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Integrations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "integration_audit_logs"
    repo Magus.Repo
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :user_id,
        :provider_key,
        :operation,
        :status,
        :ip_address,
        :metadata,
        :error_details
      ]
    end

    read :for_user do
      argument :user_id, :uuid, allow_nil?: false

      filter expr(user_id == ^arg(:user_id))
      prepare build(sort: [inserted_at: :desc], limit: 100)
    end

    read :recent_failures do
      filter expr(status == :failure)
      prepare build(sort: [inserted_at: :desc], limit: 100)
    end

    read :by_provider do
      argument :provider_key, :atom, allow_nil?: false

      filter expr(provider_key == ^arg(:provider_key))
      prepare build(sort: [inserted_at: :desc])
    end
  end

  policies do
    # Only admins can read audit logs via normal API
    # System operations use authorize?: false
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:is_admin, true)
    end

    policy action(:record) do
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :provider_key, :atom do
      public? true
    end

    attribute :operation, :string do
      allow_nil? false
      public? true
      description "The operation performed (e.g., 'send_message', 'webhook', 'credential_access')"
    end

    attribute :status, :atom do
      allow_nil? false
      constraints one_of: [:success, :failure]
      public? true
    end

    attribute :ip_address, :string do
      public? true
      description "Client IP for webhook requests"
    end

    attribute :metadata, :map do
      default %{}
      public? true
      description "Additional context (duration_ms, request_id, etc.)"
    end

    attribute :error_details, :string do
      public? true
      description "Error message on failure"
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :user, Magus.Accounts.User
  end
end
