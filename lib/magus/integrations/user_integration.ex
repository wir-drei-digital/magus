defmodule Magus.Integrations.UserIntegration do
  @moduledoc """
  Tracks which integrations a user has enabled, bound to a specific agent.

  Each agent can have one integration per provider. The integration
  stores provider-specific configuration and links to credentials.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Integrations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "user_integrations"
    repo Magus.Repo
  end

  typescript do
    type_name "UserIntegration"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :config,
        :external_id,
        :user_id,
        :custom_agent_id,
        :conversation_mode,
        :async_reply_enabled,
        :enabled_tools
      ]

      argument :provider_key, :atom, allow_nil?: false

      change set_attribute(:provider_key, arg(:provider_key))
    end

    update :activate do
      change set_attribute(:status, :active)
      change set_attribute(:error_message, nil)
    end

    update :deactivate do
      change set_attribute(:status, :disabled)
    end

    update :mark_error do
      accept [:error_message]
      change set_attribute(:status, :error)
    end

    update :update_config do
      accept [:config, :external_id, :conversation_mode, :async_reply_enabled]
    end

    update :update_enabled_tools do
      accept [:enabled_tools]
    end

    update :link_conversation do
      accept []
      require_atomic? false
      argument :conversation_id, :uuid, allow_nil?: false

      change manage_relationship(:conversation_id, :conversation, type: :append)
    end

    update :unlink_conversation do
      change set_attribute(:conversation_id, nil)
    end

    update :record_sync do
      change set_attribute(:last_sync_at, &DateTime.utc_now/0)
    end

    read :for_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
      prepare build(load: [:custom_agent])
    end

    read :for_agent do
      argument :custom_agent_id, :uuid, allow_nil?: false
      filter expr(custom_agent_id == ^arg(:custom_agent_id))
      prepare build(load: [:credential])
    end

    read :by_user_and_provider do
      argument :user_id, :uuid, allow_nil?: false
      argument :provider_key, :atom, allow_nil?: false

      filter expr(user_id == ^arg(:user_id))
      filter expr(provider_key == ^arg(:provider_key))
      prepare build(load: [:credential])
    end

    read :by_agent_and_provider do
      argument :custom_agent_id, :uuid, allow_nil?: false
      argument :provider_key, :atom, allow_nil?: false
      get? true

      filter expr(custom_agent_id == ^arg(:custom_agent_id))
      filter expr(provider_key == ^arg(:provider_key))
      prepare build(load: [:credential])
    end

    read :list_by_agent_and_provider do
      argument :custom_agent_id, :uuid, allow_nil?: false
      argument :provider_key, :atom, allow_nil?: false

      filter expr(
               custom_agent_id == ^arg(:custom_agent_id) and provider_key == ^arg(:provider_key)
             )

      prepare build(load: [:credential])
    end

    read :by_conversation do
      argument :conversation_id, :uuid, allow_nil?: false
      get? true
      filter expr(conversation_id == ^arg(:conversation_id) and status == :active)
    end

    read :active_for_provider do
      argument :provider_key, :atom, allow_nil?: false

      filter expr(provider_key == ^arg(:provider_key))
      filter expr(status == :active)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via(:user)
    end

    policy action_type(:create) do
      authorize_if changing_attributes(user_id: [to: {:_actor, :id}])
    end

    policy action_type([:update, :destroy]) do
      authorize_if relates_to_actor_via(:user)
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :provider_key, :atom do
      allow_nil? false
      public? true
      description "The provider key (e.g., :telegram, :google_calendar)"
    end

    attribute :status, :atom do
      default :pending
      constraints one_of: [:pending, :active, :error, :disabled]
      public? true
    end

    attribute :config, :map do
      default %{}
      public? true
      description "Provider-specific configuration (e.g., webhook_secret for Telegram)"
    end

    attribute :external_id, :string do
      public? true
      description "External identifier (e.g., telegram chat_id for routing)"
    end

    attribute :last_sync_at, :utc_datetime_usec do
      public? true
    end

    attribute :error_message, :string do
      public? true
    end

    attribute :conversation_mode, :atom do
      default :single
      constraints one_of: [:single, :multi]
      public? true

      description """
      How conversations are created for incoming messages:
      - :single - All messages go to one conversation (e.g., Telegram personal bot)
      - :multi - Messages are routed by identifier (e.g., Discord - each user gets their own conversation)
      """
    end

    attribute :async_reply_enabled, :boolean do
      default true
      public? true

      description "Whether to send agent responses back through this integration asynchronously via the plugin"
    end

    attribute :enabled_tools, {:array, :atom} do
      default []
      public? true

      description """
      List of tool keys that are enabled for this integration.
      Each tool key corresponds to a tool defined by the provider's tools/0 callback.
      Only enabled tools will be available to the conversation agent.
      """
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Magus.Accounts.User do
      allow_nil? false
    end

    belongs_to :custom_agent, Magus.Agents.CustomAgent do
      allow_nil? false
      description "The agent this integration is bound to"
    end

    belongs_to :conversation, Magus.Chat.Conversation do
      allow_nil? true
      description "For single mode: the linked conversation"
    end

    has_one :credential, Magus.Integrations.Credential
  end
end
