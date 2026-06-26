defmodule Magus.Chat.PaneState do
  @moduledoc """
  Tracks per-user side pane state per conversation.

  Each user in a conversation can have one open side pane at a time.
  The pane can be a thread, draft, PDF, or service. This persists across page reloads.
  """
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Chat,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "pane_states"
    repo Magus.Repo
  end

  actions do
    read :read do
      primary? true
    end

    read :by_conversation_and_user do
      argument :conversation_id, :uuid, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false
      get? true

      filter expr(conversation_id == ^arg(:conversation_id) and user_id == ^arg(:user_id))
    end

    create :set do
      accept []
      upsert? true
      upsert_identity :unique_conversation_user
      upsert_fields [:pane_type, :resource_id, :updated_at]

      argument :conversation_id, :uuid, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false

      argument :pane_type, :atom,
        allow_nil?: false,
        constraints: [one_of: [:thread, :draft, :pdf, :service, :brain]]

      argument :resource_id, :uuid, allow_nil?: false

      change set_attribute(:conversation_id, arg(:conversation_id))
      change set_attribute(:user_id, arg(:user_id))
      change set_attribute(:pane_type, arg(:pane_type))
      change set_attribute(:resource_id, arg(:resource_id))

      validate Magus.Chat.Validations.ActorOwnsPaneContext
    end

    create :dismiss do
      accept []
      upsert? true
      upsert_identity :unique_conversation_user
      upsert_fields [:pane_type, :resource_id, :updated_at]

      argument :conversation_id, :uuid, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false

      change set_attribute(:conversation_id, arg(:conversation_id))
      change set_attribute(:user_id, arg(:user_id))
      change set_attribute(:pane_type, nil)
      change set_attribute(:resource_id, nil)

      validate Magus.Chat.Validations.ActorOwnsPaneContext
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if Magus.Chat.Checks.ConversationVisibleToActor
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :pane_type, :atom do
      allow_nil? true
      constraints one_of: [:thread, :draft, :pdf, :service, :brain]
    end

    attribute :resource_id, :uuid do
      allow_nil? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :conversation, Magus.Chat.Conversation, allow_nil?: false
    belongs_to :user, Magus.Accounts.User, allow_nil?: false
  end

  identities do
    identity :unique_conversation_user, [:conversation_id, :user_id]
  end
end
