defmodule Magus.Chat.ConversationShareLink do
  @moduledoc """
  Read-only share links for conversations.

  Unlike invite links (which allow users to JOIN as participants),
  share links allow users to VIEW the conversation without participating.

  Access types:
  - :public - Anyone with the link can view (no login required)
  - :authenticated - Only logged-in users can view
  """
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Chat,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "conversation_share_links"
    repo Magus.Repo

    references do
      reference :conversation, on_delete: :delete
    end
  end

  typescript do
    type_name "ConversationShareLink"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:access_type, :label]
      argument :conversation_id, :uuid, allow_nil?: false

      change set_attribute(:conversation_id, arg(:conversation_id))
      change Magus.Chat.ConversationShareLink.Changes.GenerateToken
      change relate_actor(:created_by)
    end

    update :revoke do
      change set_attribute(:is_active, false)
    end

    read :by_token do
      argument :token, :string, allow_nil?: false
      filter expr(token == ^arg(:token) and is_active == true)
      get? true
    end

    read :active_for_conversation do
      argument :conversation_id, :uuid, allow_nil?: false
      filter expr(conversation_id == ^arg(:conversation_id) and is_active == true)
      prepare build(sort: [inserted_at: :desc])
    end
  end

  policies do
    # Create action needs custom check since relationship doesn't exist yet
    policy action(:create) do
      authorize_if Magus.Chat.ConversationShareLink.Checks.ConversationOwner
    end

    # Owner can revoke/destroy share links
    policy action([:revoke, :destroy]) do
      authorize_if expr(conversation.user_id == ^actor(:id))
    end

    # Anyone can look up a link by token (for viewing)
    policy action(:by_token) do
      authorize_if always()
    end

    # Can read links if you're the conversation owner (for listing/viewing own links)
    policy action([:read, :active_for_conversation]) do
      authorize_if expr(conversation.user_id == ^actor(:id))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :token, :string do
      allow_nil? false
      public? true
    end

    attribute :access_type, :atom do
      allow_nil? false
      default :public
      constraints one_of: [:public, :authenticated]
      public? true
      description "public: anyone can view. authenticated: must be logged in."
    end

    attribute :label, :string do
      allow_nil? true
      public? true
      description "Optional label for identifying this link"
    end

    attribute :is_active, :boolean do
      allow_nil? false
      default true
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :conversation, Magus.Chat.Conversation do
      allow_nil? false
      public? true
      attribute_writable? true
    end

    belongs_to :created_by, Magus.Accounts.User do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_token, [:token]
  end
end
