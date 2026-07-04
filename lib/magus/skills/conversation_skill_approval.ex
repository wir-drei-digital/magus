defmodule Magus.Skills.ConversationSkillApproval do
  @moduledoc """
  Records that a skill's bundled code was approved to run in a specific
  conversation. Binds to the approved bundle's sha (a content change re-gates),
  records who approved, and how (slash / card / trust).
  """
  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Skills,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "conversation_skill_approvals"
    repo Magus.Repo

    references do
      reference :conversation, on_delete: :delete
      reference :skill, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy]

    read :for_conversation do
      argument :conversation_id, :uuid, allow_nil?: false
      filter expr(conversation_id == ^arg(:conversation_id))
    end

    create :record do
      upsert? true
      upsert_identity :unique_conversation_skill
      upsert_fields [:bundle_sha, :approved_by_id, :source]

      accept [:conversation_id, :skill_id, :bundle_sha, :approved_by_id, :source]
    end
  end

  policies do
    # Recording is done by trusted internal callers (slash preflight, inbox
    # approval matcher) with authorize?: false. Reads for the current user are
    # scoped to conversations they can see.
    policy action_type(:read) do
      authorize_if expr(exists(conversation, user_id == ^actor(:id)))
    end

    policy action(:record) do
      authorize_if always()
    end

    policy action_type(:destroy) do
      authorize_if expr(exists(conversation, user_id == ^actor(:id)))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :bundle_sha, :string, allow_nil?: true, public?: true

    attribute :source, :atom do
      allow_nil? false
      default :approval_card
      constraints one_of: [:slash_command, :approval_card, :trusted]
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :conversation, Magus.Chat.Conversation, allow_nil?: false
    belongs_to :skill, Magus.Skills.Skill, allow_nil?: false
    belongs_to :approved_by, Magus.Accounts.User, allow_nil?: true
  end

  identities do
    identity :unique_conversation_skill, [:conversation_id, :skill_id]
  end
end
