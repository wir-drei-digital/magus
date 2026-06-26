defmodule Magus.Plan.Task do
  @moduledoc """
  A task within a conversation's plan.

  Tasks support single-level nesting (subtasks) and track status, assignment,
  and position within their scope (conversation + parent).
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Plan,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  postgres do
    table "plan_tasks"
    repo Magus.Repo

    references do
      reference :conversation, on_delete: :delete
      reference :parent, on_delete: :delete
      reference :assigned_to_user, on_delete: :nilify
    end
  end

  alias Magus.Plan.Task.Changes.{
    AutoPosition,
    BroadcastTaskEvent,
    NotifyAgentAssignment,
    NotifyTaskCompletion,
    SetCompletedBy,
    SpawnRecurrence,
    ValidateNesting
  }

  typescript do
    type_name "Task"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :title,
        :description,
        :status,
        :position,
        :assigned_to_agent,
        :metadata,
        :parent_id,
        :assigned_to_user_id,
        :assigned_to_custom_agent_id,
        :assigned_by_custom_agent_id,
        :blocked_reason,
        :waiting_on_user,
        :due_at,
        :recurrence
      ]

      argument :conversation_id, :uuid, allow_nil?: false

      change set_attribute(:conversation_id, arg(:conversation_id))
      change ValidateNesting
      change AutoPosition
      change BroadcastTaskEvent
      change NotifyAgentAssignment
    end

    update :update do
      primary? true

      accept [
        :title,
        :description,
        :status,
        :position,
        :assigned_to_agent,
        :metadata,
        :parent_id,
        :assigned_to_user_id,
        :assigned_to_custom_agent_id,
        :assigned_by_custom_agent_id,
        :blocked_reason,
        :waiting_on_user,
        :result_summary,
        :due_at,
        :recurrence
      ]

      require_atomic? false

      change ValidateNesting
      change SetCompletedBy
      change BroadcastTaskEvent
      change NotifyAgentAssignment
      change NotifyTaskCompletion
      change SpawnRecurrence
    end

    read :for_conversation do
      argument :conversation_id, :uuid, allow_nil?: false

      filter expr(conversation_id == ^arg(:conversation_id) and status != :archived)
      prepare build(sort: [position: :asc, inserted_at: :asc])
    end

    read :open_for_user do
      argument :user_id, :uuid, allow_nil?: false

      filter expr(
               assigned_to_user_id == ^arg(:user_id) and
                 status in [:open, :in_progress] and
                 is_nil(parent_id) and
                 is_nil(dismissed_at)
             )

      prepare build(sort: [due_at: :asc_nils_last, inserted_at: :asc], limit: 10)
    end

    update :archive do
      accept []
      change set_attribute(:status, :archived)
    end

    update :complete do
      accept []
      change set_attribute(:status, :done)
      change set_attribute(:completed_by, "user")
    end

    update :dismiss do
      accept []
      change set_attribute(:dismissed_at, &DateTime.utc_now/0)
    end
  end

  policies do
    bypass action_type([:read, :create, :update, :destroy]) do
      authorize_if Magus.Checks.IsAiAgent
    end

    policy action_type(:read) do
      authorize_if expr(conversation.user_id == ^actor(:id))

      authorize_if expr(
                     exists(
                       conversation.members,
                       user_id == ^actor(:id) and not is_nil(accepted_at)
                     )
                   )

      authorize_if expr(
                     not is_nil(conversation.workspace_id) and
                       conversation.is_shared_to_workspace == true and
                       exists(
                         conversation.workspace.members,
                         is_active == true and user_id == ^actor(:id)
                       )
                   )
    end

    policy action_type(:create) do
      authorize_if Magus.Chat.Checks.ActorCanWriteConversation
    end

    policy action_type([:update, :destroy]) do
      authorize_if {Magus.Chat.Checks.ActorCanWriteConversation, field: :conversation_id}
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      allow_nil? true
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :open
      public? true
      constraints one_of: [:open, :in_progress, :done, :cancelled, :archived, :blocked]
    end

    attribute :position, :integer do
      allow_nil? true
      public? true
    end

    attribute :assigned_to_agent, :string do
      allow_nil? true
      default "assistant"
      public? true
    end

    attribute :completed_by, :string do
      allow_nil? true
      public? true
    end

    attribute :assigned_to_custom_agent_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :assigned_by_custom_agent_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :blocked_reason, :string do
      allow_nil? true
      public? true
    end

    attribute :waiting_on_user, :boolean do
      default false
      public? true
    end

    attribute :result_summary, :string do
      allow_nil? true
      public? true
      description "Summary of the completed work (set automatically from AgentRun result_text)"
    end

    attribute :metadata, :map do
      default %{}
      public? true
    end

    attribute :due_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "When this task should be completed"
    end

    attribute :dismissed_at, :utc_datetime_usec do
      allow_nil? true
      public? true

      description "When the user dismissed this task from their startpage (task stays open in its conversation)"
    end

    attribute :recurrence, :map do
      allow_nil? true
      public? true

      description "Recurrence pattern: %{frequency: :daily|:weekly|:monthly, interval: 1, days: [:monday]}"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :conversation, Magus.Chat.Conversation do
      allow_nil? false
      public? true
    end

    belongs_to :parent, __MODULE__ do
      allow_nil? true
      public? true
    end

    has_many :subtasks, __MODULE__ do
      destination_attribute :parent_id
      public? true
    end

    belongs_to :assigned_to_user, Magus.Accounts.User do
      allow_nil? true
      public? true
    end
  end
end
