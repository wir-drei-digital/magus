defmodule Magus.Integrations.InputMessage do
  @moduledoc """
  Incoming messages from external integrations.

  Records messages received via webhooks or polling from providers
  like Telegram, Discord, or Email. The Input Agent processes these
  and decides how to handle them (quick response, create conversation, etc.).
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Integrations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshOban]

  postgres do
    table "integration_input_messages"
    repo Magus.Repo

    identity_wheres_to_sql unique_external: "external_id IS NOT NULL"
  end

  oban do
    triggers do
      trigger :fail_stuck do
        action :fail_stuck_message
        queue :input_message_sweep
        scheduler_cron "*/15 * * * *"
        read_action :stuck_processing
        worker_read_action :stuck_processing
        where expr(is_stuck_processing)
        worker_module_name Magus.Integrations.InputMessage.Workers.FailStuck
        scheduler_module_name Magus.Integrations.InputMessage.Schedulers.FailStuck
        max_attempts 1
      end
    end
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :provider_key,
        :external_id,
        :message_type,
        :payload,
        :raw_payload,
        :user_id,
        :user_integration_id,
        :dispatched
      ]

      # Signal the Input Agent to process this message after creation
      change Magus.Integrations.InputMessage.Changes.SignalInputAgent
    end

    update :mark_processed do
      change set_attribute(:status, :processed)
      change set_attribute(:processed_at, &DateTime.utc_now/0)
    end

    update :mark_processing do
      change set_attribute(:status, :processing)
    end

    update :mark_failed do
      accept [:error_message]
      change set_attribute(:status, :failed)
    end

    update :fail_stuck_message do
      description """
      Oban-triggered: fails an InputMessage stuck in :processing (gated
      upstream by `stuck_processing`, which the `:fail_stuck` trigger's
      `where` clause uses to select candidates).
      """

      accept []
      change set_attribute(:status, :failed)
      change set_attribute(:error_message, "Processing timed out after 10 minutes")
    end

    update :route_to_conversation do
      accept [:routed_to_conversation_id]
    end

    read :stuck_processing do
      description """
      InputMessages stuck in :processing for more than 10 minutes (by
      updated_at). Backs the 15-minute `:fail_stuck` trigger.
      """

      pagination keyset?: true, required?: false
      filter expr(is_stuck_processing)
    end

    read :pending do
      filter expr(status == :pending)
      prepare build(sort: [received_at: :asc])

      pagination do
        offset? true
        default_limit 10
        countable true
      end
    end

    read :recent do
      argument :user_id, :uuid, allow_nil?: false

      filter expr(user_id == ^arg(:user_id))
      prepare build(sort: [received_at: :desc], limit: 50)
    end

    read :count_pending do
      argument :user_id, :uuid, allow_nil?: false

      filter expr(user_id == ^arg(:user_id) and status == :pending)
    end

    read :count_processed_today do
      argument :user_id, :uuid, allow_nil?: false

      filter expr(
               user_id == ^arg(:user_id) and
                 status == :processed and
                 processed_at >= ago(1, :day)
             )
    end
  end

  policies do
    # The 15-minute stuck-message sweep reads/updates across all users'
    # InputMessages with no real actor; AshOban authorizes its own calls via
    # this check (mirrors AgentRun / CustomAgent's watchdog triggers).
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

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

    attribute :external_id, :string do
      public? true
      description "Provider's message ID for deduplication"
    end

    attribute :message_type, :atom do
      allow_nil? false
      constraints one_of: [:text, :image, :file, :audio, :video, :event, :callback, :unknown]
      public? true
    end

    attribute :payload, :map do
      allow_nil? false
      public? true
      description "Normalized message data"
    end

    attribute :raw_payload, :map do
      public? true
      description "Original provider payload for debugging"
    end

    attribute :status, :atom do
      default :pending
      constraints one_of: [:pending, :processing, :processed, :failed]
      public? true
    end

    attribute :processed_at, :utc_datetime_usec do
      public? true
    end

    attribute :error_message, :string do
      public? true
    end

    attribute :dispatched, :boolean do
      default false
      allow_nil? false
      public? true

      description "Whether the message has already been dispatched (e.g. by API controller synchronously)"
    end

    create_timestamp :received_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      allow_nil? false
    end

    belongs_to :user_integration, Magus.Integrations.UserIntegration

    belongs_to :routed_to_conversation, Magus.Chat.Conversation
  end

  calculations do
    calculate :is_stuck_processing, :boolean do
      public? false

      calculation expr(
                    status == :processing and
                      updated_at < ago(10, :minute)
                  )
    end
  end

  identities do
    identity :unique_external, [:user_id, :provider_key, :external_id],
      where: expr(not is_nil(external_id))
  end
end
