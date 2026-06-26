defmodule Magus.Plan.TaskPaneState do
  @moduledoc """
  Tracks per-user task pane visibility state per conversation.

  Each user in a conversation independently controls whether the task pane
  is shown or hidden. This persists across page reloads.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Plan,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "plan_task_pane_states"
    repo Magus.Repo
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
    end

    create :dismiss do
      accept []
      upsert? true
      upsert_identity :unique_conversation_user
      upsert_fields [:pane_open, :updated_at]

      argument :conversation_id, :uuid, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false

      change set_attribute(:conversation_id, arg(:conversation_id))
      change set_attribute(:user_id, arg(:user_id))
      change set_attribute(:pane_open, false)

      validate Magus.Chat.Validations.ActorOwnsPaneContext
    end

    create :reopen do
      accept []
      upsert? true
      upsert_identity :unique_conversation_user
      upsert_fields [:pane_open, :updated_at]

      argument :conversation_id, :uuid, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false

      change set_attribute(:conversation_id, arg(:conversation_id))
      change set_attribute(:user_id, arg(:user_id))
      change set_attribute(:pane_open, true)

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

    attribute :pane_open, :boolean do
      allow_nil? false
      default true
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
