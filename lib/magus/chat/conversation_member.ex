defmodule Magus.Chat.ConversationMember do
  @moduledoc """
  Represents a user's membership in a multiplayer conversation.

  Roles:
  - :owner - Full control (add/remove members, manage invites, change roles)
  - :member - Can participate (send messages, read all messages, change their model); usage billed to them
  - :observer - Read-only access (can see messages but cannot send them)
  """
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Chat,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub],
    extensions: [AshTypescript.Resource]

  postgres do
    table "conversation_members"
    repo Magus.Repo
  end

  typescript do
    type_name "ConversationMember"
  end

  actions do
    defaults [:read, :destroy]

    create :add_member do
      accept [:role]
      argument :conversation_id, :uuid, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false
      argument :invited_by_id, :uuid, allow_nil?: true

      change set_attribute(:conversation_id, arg(:conversation_id))
      change set_attribute(:user_id, arg(:user_id))
      change set_attribute(:invited_by_id, arg(:invited_by_id))
      change set_attribute(:invited_at, &DateTime.utc_now/0)
    end

    create :add_owner do
      argument :conversation_id, :uuid, allow_nil?: false
      argument :user_id, :uuid, allow_nil?: false

      upsert? true
      upsert_identity :unique_membership
      upsert_fields [:role, :accepted_at]

      change set_attribute(:conversation_id, arg(:conversation_id))
      change set_attribute(:user_id, arg(:user_id))
      change set_attribute(:role, :owner)
      change set_attribute(:accepted_at, &DateTime.utc_now/0)
    end

    update :accept_invitation do
      change set_attribute(:accepted_at, &DateTime.utc_now/0)
    end

    update :change_role do
      accept [:role]
    end

    update :mute do
      change set_attribute(:is_muted, true)
    end

    update :unmute do
      change set_attribute(:is_muted, false)
    end

    read :for_conversation do
      argument :conversation_id, :uuid, allow_nil?: false
      filter expr(conversation_id == ^arg(:conversation_id))
    end

    read :accepted_for_conversation do
      argument :conversation_id, :uuid, allow_nil?: false
      filter expr(conversation_id == ^arg(:conversation_id) and not is_nil(accepted_at))
    end

    read :my_memberships do
      filter expr(user_id == ^actor(:id) and not is_nil(accepted_at))
    end

    read :pending_invitations do
      filter expr(user_id == ^actor(:id) and is_nil(accepted_at))
    end
  end

  policies do
    # System actors (AI agents) can manage members for thread creation
    bypass action([:add_member, :accept_invitation]) do
      authorize_if Magus.Checks.IsAiAgent
    end

    # Only owner can add members
    policy action(:add_member) do
      authorize_if Magus.Chat.ConversationInvitation.Checks.ActorIsConversationOwner
    end

    # Only owner can change existing members
    policy action([:change_role, :mute, :unmute]) do
      authorize_if expr(
                     exists(
                       conversation.members,
                       user_id == ^actor(:id) and role == :owner
                     )
                   )
    end

    # Users can leave (remove themselves), owners can kick anyone
    policy action(:destroy) do
      authorize_if expr(user_id == ^actor(:id))

      authorize_if expr(
                     exists(
                       conversation.members,
                       user_id == ^actor(:id) and role == :owner
                     )
                   )
    end

    # Owner auto-add is a system action
    policy action(:add_owner) do
      authorize_if always()
    end

    # Accept invitation - only the invited user
    policy action(:accept_invitation) do
      authorize_if expr(user_id == ^actor(:id))
    end

    # Can read members if you're the conversation owner or a member
    policy action_type(:read) do
      authorize_if expr(conversation.user_id == ^actor(:id))

      authorize_if expr(
                     exists(
                       conversation.members,
                       user_id == ^actor(:id)
                     )
                   )
    end
  end

  pub_sub do
    module MagusWeb.Endpoint
    prefix "chat"

    publish_all :create, ["members", :conversation_id]
    publish_all :update, ["members", :conversation_id]

    publish_all :destroy, ["members", :conversation_id] do
      event "member_removed"
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom do
      allow_nil? false
      default :member
      constraints one_of: [:owner, :member, :observer]
      public? true
    end

    attribute :invited_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :accepted_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :is_muted, :boolean do
      allow_nil? false
      default false
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

    belongs_to :user, Magus.Accounts.User do
      allow_nil? false
      public? true
    end

    belongs_to :invited_by, Magus.Accounts.User do
      allow_nil? true
      public? true
    end
  end

  identities do
    identity :unique_membership, [:conversation_id, :user_id]
  end
end
