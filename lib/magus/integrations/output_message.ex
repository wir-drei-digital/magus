defmodule Magus.Integrations.OutputMessage do
  @moduledoc """
  Outgoing messages to external integrations.

  Records messages sent via providers like Telegram, Discord, or Email.
  Includes retry tracking and status for delivery confirmation.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Integrations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "integration_output_messages"
    repo Magus.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :provider_key,
        :operation,
        :payload,
        :user_id,
        :user_integration_id,
        :triggered_by_input_id
      ]
    end

    update :mark_sent do
      accept [:external_id]
      change set_attribute(:status, :sent)
      change set_attribute(:sent_at, &DateTime.utc_now/0)
    end

    update :mark_failed do
      accept [:error_message]
      change set_attribute(:status, :failed)
      change atomic_update(:retry_count, expr(retry_count + 1))
    end

    read :recent do
      argument :user_id, :uuid, allow_nil?: false

      filter expr(user_id == ^arg(:user_id))
      prepare build(sort: [inserted_at: :desc], limit: 50)
    end

    read :pending do
      filter expr(status == :pending)
      prepare build(sort: [inserted_at: :asc])
    end

    read :count_today do
      argument :user_integration_id, :uuid, allow_nil?: false

      filter expr(
               user_integration_id == ^arg(:user_integration_id) and
                 inserted_at >= ago(1, :day)
             )
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:user)
    end

    policy action_type([:create, :update]) do
      authorize_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :provider_key, :atom do
      allow_nil? false
      public? true
    end

    attribute :operation, :atom do
      allow_nil? false
      public? true
      description "The operation performed (e.g., :send_message, :create_event)"
    end

    attribute :payload, :map do
      allow_nil? false
      public? true
      description "The data sent to the provider"
    end

    attribute :status, :atom do
      default :pending
      constraints one_of: [:pending, :sent, :failed]
      public? true
    end

    attribute :external_id, :string do
      public? true
      description "Response ID from provider for tracking"
    end

    attribute :sent_at, :utc_datetime_usec do
      public? true
    end

    attribute :error_message, :string do
      public? true
    end

    attribute :retry_count, :integer do
      default 0
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      allow_nil? false
    end

    belongs_to :user_integration, Magus.Integrations.UserIntegration

    belongs_to :triggered_by_input, Magus.Integrations.InputMessage
  end
end
