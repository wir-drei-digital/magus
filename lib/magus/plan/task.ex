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
    extensions: [AshTypescript.Resource, AshOban]

  postgres do
    table "plan_tasks"
    repo Magus.Repo

    references do
      reference :conversation, on_delete: :delete
      reference :brain_page, on_delete: :delete
      reference :parent, on_delete: :delete
      reference :assigned_to_user, on_delete: :nilify
    end

    check_constraints do
      check_constraint :conversation_id, "plan_tasks_exactly_one_container",
        check: "(conversation_id IS NULL) <> (brain_page_id IS NULL)",
        message: "task must belong to exactly one of a conversation or a plan page"
    end
  end

  typescript do
    type_name "Task"
  end

  alias Magus.Plan.Task.Changes.{
    AutoPosition,
    BroadcastTaskEvent,
    ClaimTask,
    DefaultUnassigned,
    EnforceTaskCap,
    NotifyAgentAssignment,
    NotifyTaskCompletion,
    RecordTaskEvent,
    RenewLease,
    SetCompletedBy,
    SpawnRecurrence,
    ValidateContainer,
    ValidateNesting,
    VerifyClaimant
  }

  oban do
    triggers do
      trigger :reap_expired_claims do
        action :reap_expired_claims
        queue :plan_task_cleanup
        scheduler_cron "*/2 * * * *"
        read_action :stale_claims
        worker_read_action :stale_claims
        where expr(is_stale)
        worker_module_name Magus.Plan.Task.Workers.ReapExpiredClaims
        scheduler_module_name Magus.Plan.Task.Schedulers.ReapExpiredClaims
        max_attempts 1
      end
    end
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
        :priority,
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
      change ValidateContainer
      change ValidateNesting
      change AutoPosition
      change BroadcastTaskEvent
      change NotifyAgentAssignment
    end

    create :create_plan do
      description "Create a task that belongs to a Brain plan page (defaults unassigned)."

      accept [
        :title,
        :description,
        :status,
        :position,
        :priority,
        :metadata,
        :parent_id,
        :assigned_to_user_id,
        :assigned_to_agent,
        :blocked_reason,
        :due_at,
        :created_by_label
      ]

      argument :brain_page_id, :uuid, allow_nil?: false

      change set_attribute(:brain_page_id, arg(:brain_page_id))

      change DefaultUnassigned

      change EnforceTaskCap
      change ValidateContainer
      change ValidateNesting
      change AutoPosition
      change BroadcastTaskEvent
      change {RecordTaskEvent, kind: :created}
    end

    update :update do
      primary? true

      accept [
        :title,
        :description,
        :status,
        :position,
        :priority,
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

      change ValidateContainer
      change ValidateNesting
      change SetCompletedBy
      change RenewLease
      change BroadcastTaskEvent
      change NotifyAgentAssignment
      change NotifyTaskCompletion
      change SpawnRecurrence
      change {RecordTaskEvent, kind: :status_changed}
    end

    read :for_conversation do
      argument :conversation_id, :uuid, allow_nil?: false

      filter expr(conversation_id == ^arg(:conversation_id) and status != :archived)
      prepare build(sort: [position: :asc, inserted_at: :asc])
    end

    read :for_plan do
      argument :brain_page_id, :uuid, allow_nil?: false

      filter expr(brain_page_id == ^arg(:brain_page_id) and status != :archived)
      prepare build(sort: [position: :asc, inserted_at: :asc])
    end

    read :ready_for_plan do
      argument :brain_page_id, :uuid, allow_nil?: false

      # Reuse the `ready` calculation rather than duplicating its predicate.
      filter expr(brain_page_id == ^arg(:brain_page_id) and ready == true)

      prepare build(sort: [priority_rank: :asc, position: :asc])
    end

    read :ready_for_brain do
      description "Ready (open + unassigned + deps-clear) tasks across every plan page in a brain."
      argument :brain_id, :uuid, allow_nil?: false

      filter expr(brain_page.brain_id == ^arg(:brain_id) and ready == true)
      prepare build(sort: [priority_rank: :asc, position: :asc])
    end

    read :for_brain do
      description "All non-archived tasks across every plan page in a brain."
      argument :brain_id, :uuid, allow_nil?: false

      filter expr(brain_page.brain_id == ^arg(:brain_id) and status != :archived)
      prepare build(sort: [priority_rank: :asc, position: :asc])
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

    read :stale_claims do
      description "In-progress tasks whose lease has expired (reaper input). Mirrors AgentRun :stale_runs."
      pagination keyset?: true, required?: false
      filter expr(is_stale)
    end

    update :archive do
      accept []
      change set_attribute(:status, :archived)
    end

    update :complete do
      accept []
      change set_attribute(:status, :done)
      change set_attribute(:completed_by, "user")
      change set_attribute(:lease_expires_at, nil)
    end

    update :claim do
      description "Atomically claim an unassigned, open task."
      require_atomic? false
      accept [:assigned_to_user_id, :assigned_to_agent]

      validate present([:assigned_to_user_id, :assigned_to_agent], at_least: 1)

      change ClaimTask
      change set_attribute(:status, :in_progress)
      change set_attribute(:claimed_at, &DateTime.utc_now/0)
      change {RenewLease, always: true}
      change BroadcastTaskEvent
      change {RecordTaskEvent, kind: :claimed}
    end

    update :release do
      description "Release a claim, returning the task to open/unassigned."
      require_atomic? false
      accept []

      change set_attribute(:assigned_to_agent, nil)
      change set_attribute(:assigned_to_user_id, nil)
      change set_attribute(:claimed_at, nil)
      change set_attribute(:lease_expires_at, nil)
      change set_attribute(:status, :open)
      change BroadcastTaskEvent
      change {RecordTaskEvent, kind: :released}
    end

    update :reap_expired_claims do
      description "AshOban-triggered: return an expired-lease task to the ready pool."
      require_atomic? false
      accept []

      change set_attribute(:assigned_to_agent, nil)
      change set_attribute(:assigned_to_user_id, nil)
      change set_attribute(:assigned_to_custom_agent_id, nil)
      change set_attribute(:assigned_by_custom_agent_id, nil)
      change set_attribute(:claimed_at, nil)
      change set_attribute(:lease_expires_at, nil)
      change set_attribute(:status, :open)
      change BroadcastTaskEvent
      change {RecordTaskEvent, kind: :lease_expired, actor_label: "system:lease-reaper"}
    end

    update :heartbeat do
      description "Renew the lease on an in-progress task the caller still owns (claimant matched by the --as label)."
      require_atomic? false
      accept []

      argument :as, :string, allow_nil?: true

      change VerifyClaimant
      change {RenewLease, always: true}
    end

    update :dismiss do
      accept []
      change set_attribute(:dismissed_at, &DateTime.utc_now/0)
    end
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    bypass action_type([:read, :create, :update, :destroy]) do
      authorize_if Magus.Checks.IsAiAgent
    end

    policy action([:for_plan, :ready_for_plan]) do
      # Strict so a non-member is forbidden (error) rather than silently filtered
      # to an empty list: ActorCanAccessTaskPage is a simple check, not a filter.
      access_type :strict
      authorize_if {Magus.Plan.Checks.ActorCanAccessTaskPage, min_role: :viewer}
    end

    # Conversation-scoped reads. `:for_plan` is governed solely by the page check
    # above; including it here would AND these conversation filters in and drop
    # all plan-task rows (a plan task has no conversation).
    policy action([:for_conversation, :open_for_user]) do
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

    # The generic `:read` (used by `get_task`) authorizes BOTH conversation tasks
    # the actor can see AND plan tasks whose brain is accessible. Within one
    # policy Ash OR's the `authorize_if`s, so the conversation exprs and the
    # `:via_brain_page` filter combine as an OR filter: a row is returned if it
    # is a visible conversation task OR an accessible plan task.
    policy action(:read) do
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

      authorize_if {Magus.Brain.Checks.BrainAccessFilter,
                    path: :via_brain_page, min_role: :viewer}
    end

    # The brain-level rollup read (`:for_brain`). Strict (like `:for_plan`) so a
    # non-member is FORBIDDEN (error) rather than silently filtered to an empty
    # list: `brain_task_overview/2` relies on this `{:error, _}` to gate the
    # internal TaskEvent read. The check resolves the brain via the `:brain_id`
    # argument and delegates to the brain's own `:read` policy.
    policy action([:for_brain, :ready_for_brain]) do
      access_type :strict
      authorize_if {Magus.Plan.Checks.ActorCanAccessTaskPage, field: :brain_id, min_role: :viewer}
    end

    policy action(:create) do
      authorize_if Magus.Chat.Checks.ActorCanWriteConversation
    end

    policy action(:create_plan) do
      authorize_if {Magus.Plan.Checks.ActorCanAccessTaskPage, min_role: :editor}
    end

    policy action_type([:update, :destroy]) do
      authorize_if {Magus.Chat.Checks.ActorCanWriteConversation, field: :conversation_id}

      authorize_if {Magus.Plan.Checks.ActorCanAccessTaskPage,
                    field: :brain_page_id, min_role: :editor}
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

    attribute :priority, :atom do
      allow_nil? false
      default :normal
      public? true
      constraints one_of: [:urgent, :high, :normal, :low]
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

    attribute :claimed_at, :utc_datetime_usec do
      allow_nil? true
      public? true
      description "When the current owner claimed the task (set by :claim, cleared by :release)."
    end

    attribute :lease_expires_at, :utc_datetime_usec do
      allow_nil? true
      public? true

      description "When the current claim's lease expires. Set by :claim, renewed by :heartbeat / activity, cleared by :release and the reaper. Null-lease claims are never reaped."
    end

    attribute :created_by_label, :string do
      allow_nil? true
      public? true

      description "Free-form lineage label of whoever created the task (the agent's --as label), sanitized at the boundary. Never converted to an atom."
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
      allow_nil? true
      public? true
    end

    belongs_to :brain_page, Magus.Brain.Page do
      allow_nil? true
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

    has_many :dependencies, Magus.Plan.TaskDependency do
      destination_attribute :task_id
      public? true
    end

    belongs_to :assigned_to_user, Magus.Accounts.User do
      allow_nil? true
      public? true
    end
  end

  calculations do
    calculate :ready,
              :boolean,
              expr(
                status == :open and
                  is_nil(assigned_to_user_id) and
                  is_nil(assigned_to_agent) and
                  is_nil(assigned_to_custom_agent_id) and
                  not exists(dependencies, depends_on.status != :done)
              ) do
      public? true
    end

    calculate :priority_rank,
              :integer,
              expr(
                fragment(
                  "CASE ? WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'normal' THEN 2 ELSE 3 END",
                  priority
                )
              )

    calculate :is_stale,
              :boolean,
              expr(
                status == :in_progress and
                  not is_nil(brain_page_id) and
                  not is_nil(lease_expires_at) and
                  lease_expires_at < now()
              )
  end

  aggregates do
    # Selectable over RPC for the board's subtask progress bar and "blocks N"
    # / "deps clear" sub-badges. `open_dependencies_count` counts unmet
    # dependencies (the same predicate the `ready` calc uses).
    count :subtask_count, :subtasks do
      public? true
    end

    # Completed subtasks, so the board can show real "done / total" progress.
    count :completed_subtask_count, :subtasks do
      public? true
      filter expr(status == :done)
    end

    count :open_dependencies_count, :dependencies do
      public? true
      filter expr(depends_on.status != :done)
    end
  end
end
