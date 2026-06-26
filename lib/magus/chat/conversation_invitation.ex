defmodule Magus.Chat.ConversationInvitation do
  @moduledoc """
  Email-based invitations for multiplayer conversations.

  These are invitations sent to specific email addresses. The recipient
  may or may not have an account yet. When they click the invite link:
  - If logged in with matching email: auto-join the conversation
  - If not logged in: redirect to sign-in/sign-up, then auto-join
  """
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Chat,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "conversation_invitations"
    repo Magus.Repo
  end

  typescript do
    type_name "ConversationInvitation"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:email, :role]
      argument :conversation_id, :uuid, allow_nil?: false

      change set_attribute(:conversation_id, arg(:conversation_id))
      change {Magus.Chat.ConversationInvitation.Changes.GenerateToken, []}
      change relate_actor(:invited_by)
    end

    read :by_token do
      argument :token, :string, allow_nil?: false
      filter expr(token == ^arg(:token) and is_nil(accepted_at))
      get? true
    end

    read :by_email do
      argument :email, :ci_string, allow_nil?: false
      argument :conversation_id, :uuid, allow_nil?: false

      filter expr(
               email == ^arg(:email) and conversation_id == ^arg(:conversation_id) and
                 is_nil(accepted_at)
             )

      get? true
    end

    read :pending_for_conversation do
      argument :conversation_id, :uuid, allow_nil?: false
      filter expr(conversation_id == ^arg(:conversation_id) and is_nil(accepted_at))
    end

    update :accept do
      change set_attribute(:accepted_at, &DateTime.utc_now/0)
    end
  end

  policies do
    # Create uses a custom check since we can't use relationship filters on create
    policy action(:create) do
      authorize_if Magus.Chat.ConversationInvitation.Checks.ActorIsConversationOwner
    end

    # Destroy can use the expression since the record exists
    policy action(:destroy) do
      authorize_if expr(
                     exists(
                       conversation.members,
                       user_id == ^actor(:id) and role == :owner
                     )
                   )
    end

    # Anyone can look up by token (for joining)
    policy action(:by_token) do
      authorize_if always()
    end

    # System can check by email
    policy action(:by_email) do
      authorize_if always()
    end

    # Accept is a system action (done after auth verification)
    policy action(:accept) do
      authorize_if always()
    end

    # Owner can read pending invitations
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

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    attribute :token, :string do
      allow_nil? false
      public? true
    end

    attribute :role, :atom do
      allow_nil? false
      default :member
      constraints one_of: [:member, :observer]
      public? true
    end

    attribute :accepted_at, :utc_datetime_usec do
      allow_nil? true
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

    belongs_to :invited_by, Magus.Accounts.User do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_token, [:token]
    identity :unique_email_per_conversation, [:conversation_id, :email]
  end
end
