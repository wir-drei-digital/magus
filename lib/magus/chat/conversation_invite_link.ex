defmodule Magus.Chat.ConversationInviteLink do
  @moduledoc """
  Public invite links for multiplayer conversations.

  Invite links can be:
  - Password protected (optional)
  - Limited to a maximum number of uses
  - Set to expire at a specific time
  - Configured to assign a specific role to joiners
  """
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Chat,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "conversation_invite_links"
    repo Magus.Repo
  end

  typescript do
    type_name "ConversationInviteLink"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:expires_at, :max_uses, :role]
      argument :conversation_id, :uuid, allow_nil?: false
      argument :password, :string, allow_nil?: true, sensitive?: true

      change set_attribute(:conversation_id, arg(:conversation_id))
      change {Magus.Chat.ConversationInviteLink.Changes.GenerateToken, []}
      change {Magus.Chat.ConversationInviteLink.Changes.HashPassword, []}
      change relate_actor(:created_by)
    end

    update :update do
      accept [:expires_at, :max_uses, :is_active]
    end

    update :deactivate do
      change set_attribute(:is_active, false)
    end

    read :by_token do
      argument :token, :string, allow_nil?: false
      filter expr(token == ^arg(:token) and is_active == true)
      get? true
    end

    read :for_conversation do
      argument :conversation_id, :uuid, allow_nil?: false
      filter expr(conversation_id == ^arg(:conversation_id))
    end

    read :active_for_conversation do
      argument :conversation_id, :uuid, allow_nil?: false
      filter expr(conversation_id == ^arg(:conversation_id) and is_active == true)
    end

    update :increment_uses do
      change atomic_update(:uses_count, expr(uses_count + 1))
    end
  end

  policies do
    # Create: can't filter via relationship on creates, use a custom check
    policy action(:create) do
      authorize_if Magus.Chat.ConversationInviteLink.Checks.IsConversationOwner
    end

    # Update/destroy: record exists so relationship filter works
    policy action([:update, :deactivate, :destroy]) do
      authorize_if expr(
                     exists(
                       conversation.members,
                       user_id == ^actor(:id) and role == :owner
                     )
                   )
    end

    # Anyone can look up a link by token (for joining)
    policy action(:by_token) do
      authorize_if always()
    end

    # Increment uses is a system action
    policy action(:increment_uses) do
      authorize_if always()
    end

    # Can read links if you're the conversation owner
    policy action_type(:read) do
      authorize_if expr(
                     exists(
                       conversation.members,
                       user_id == ^actor(:id) and role == :owner
                     )
                   )
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :token, :string do
      allow_nil? false
      public? true
    end

    attribute :password_hash, :string do
      allow_nil? true
      sensitive? true
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :max_uses, :integer do
      allow_nil? true
      public? true
    end

    attribute :uses_count, :integer do
      allow_nil? false
      default 0
      public? true
    end

    attribute :is_active, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :role, :atom do
      allow_nil? false
      default :member
      constraints one_of: [:member, :observer]
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :conversation, Magus.Chat.Conversation do
      allow_nil? false
      public? true
    end

    belongs_to :created_by, Magus.Accounts.User do
      allow_nil? false
      public? true
    end
  end

  calculations do
    calculate :is_expired, :boolean do
      calculation expr(not is_nil(expires_at) and expires_at < now())
    end

    calculate :is_exhausted, :boolean do
      calculation expr(not is_nil(max_uses) and uses_count >= max_uses)
    end

    calculate :is_valid, :boolean do
      calculation expr(is_active and not is_expired and not is_exhausted)
    end

    calculate :has_password, :boolean do
      calculation expr(not is_nil(password_hash))
    end
  end

  identities do
    identity :unique_token, [:token]
  end
end
