defmodule Magus.Integrations.IntegrationConversation do
  @moduledoc """
  Maps external identifiers to conversations for multi-mode integrations.

  In multi-mode (e.g., Discord where each user gets their own conversation),
  this resource tracks the mapping from external identifier to conversation.

  For single-mode integrations, the conversation is stored directly on the
  UserIntegration resource.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Integrations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "integration_conversations"
    repo Magus.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:external_identifier]

      argument :user_integration_id, :uuid, allow_nil?: false
      argument :conversation_id, :uuid, allow_nil?: false

      change manage_relationship(:user_integration_id, :user_integration, type: :append)
      change manage_relationship(:conversation_id, :conversation, type: :append)
    end

    read :by_identifier do
      argument :user_integration_id, :uuid, allow_nil?: false
      argument :external_identifier, :string, allow_nil?: false
      get? true

      filter expr(user_integration_id == ^arg(:user_integration_id))
      filter expr(external_identifier == ^arg(:external_identifier))
    end

    read :for_integration do
      argument :user_integration_id, :uuid, allow_nil?: false
      filter expr(user_integration_id == ^arg(:user_integration_id))
    end

    read :by_conversation_id do
      argument :conversation_id, :uuid, allow_nil?: false
      get? true
      filter expr(conversation_id == ^arg(:conversation_id))
      prepare build(load: [:user_integration])
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if relates_to_actor_via([:user_integration, :user])
    end

    policy action(:create) do
      authorize_if Magus.Integrations.IntegrationConversation.Checks.ActorOwnsUserIntegration
    end

    policy action_type(:destroy) do
      authorize_if relates_to_actor_via([:user_integration, :user])
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :external_identifier, :string do
      allow_nil? false
      public? true
      description "Provider-specific identifier (e.g., Discord user ID, Slack channel ID)"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user_integration, Magus.Integrations.UserIntegration do
      allow_nil? false
    end

    belongs_to :conversation, Magus.Chat.Conversation do
      allow_nil? false
    end
  end

  identities do
    identity :unique_integration_identifier, [:user_integration_id, :external_identifier]
  end
end
