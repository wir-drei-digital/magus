defmodule Magus.Usage.Override do
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Usage,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "user_usage_overrides"
    repo Magus.Repo
  end

  actions do
    defaults [:read, :destroy]

    read :active_for_user do
      argument :user_id, :uuid, allow_nil?: false

      filter expr(
               user_id == ^arg(:user_id) and
                 (is_nil(expires_at) or expires_at > now())
             )
    end

    create :create do
      accept [
        :user_id,
        :override_type,
        :bonus_storage_bytes,
        :exempt_from_limits,
        :reason,
        :expires_at
      ]
    end

    update :update do
      accept [
        :override_type,
        :bonus_storage_bytes,
        :exempt_from_limits,
        :reason,
        :expires_at
      ]
    end
  end

  policies do
    # Only admins can manage overrides
    policy action_type(:read) do
      authorize_if Magus.Checks.IsAdmin
    end

    policy action_type(:create) do
      authorize_if Magus.Checks.IsAdmin
    end

    policy action_type(:update) do
      authorize_if Magus.Checks.IsAdmin
    end

    policy action_type(:destroy) do
      authorize_if Magus.Checks.IsAdmin
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :override_type, :atom do
      constraints one_of: [:bonus, :exemption, :promotional]
      allow_nil? false
      public? true
      description "Type of override: bonus adds to limits, exemption bypasses all"
    end

    attribute :bonus_storage_bytes, :integer do
      allow_nil? true
      default 0
      public? true
      description "Additional storage in bytes"
    end

    attribute :exempt_from_limits, :boolean do
      allow_nil? false
      default false
      public? true
      description "If true, user bypasses all usage limits"
    end

    attribute :reason, :string do
      allow_nil? true
      description "Admin notes explaining why override was granted"
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "When override expires. nil = never expires"
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      allow_nil? false
    end
  end
end
