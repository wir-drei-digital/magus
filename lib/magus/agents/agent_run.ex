defmodule Magus.Agents.AgentRun do
  @moduledoc """
  Tracks cross-agent executions (consult, delegate, subtask).

  Each AgentRun represents a single execution request routed to a target
  agent conversation. The source conversation receives lifecycle updates
  (`run.started`, `run.progress`, `run.completed`, `run.failed`).

  Lifecycle: pending -> running -> complete | error | timed_out | cancelled | budget_exceeded
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Agents,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "agent_runs"
    repo Magus.Repo

    references do
      # `event_id` -> agent_inbox_events was created with a plain FK (default
      # ON DELETE RESTRICT). The daily prune job destroys terminal inbox events
      # older than 30 days; a younger run still referencing such an event via
      # `event_id` would otherwise make the destroy raise a FK violation.
      # Nilify so pruning an old event just clears the stale back-reference.
      reference :triggering_event, on_delete: :nilify
    end

    identity_wheres_to_sql unique_idempotency_key: "idempotency_key IS NOT NULL"
  end

  oban do
    triggers do
      trigger :cleanup_stale_runs do
        action :cleanup_stale
        queue :agent_run_cleanup
        scheduler_cron "*/5 * * * *"
        read_action :stale_runs
        worker_read_action :stale_runs
        where expr(is_stale)
        worker_module_name Magus.Agents.AgentRun.Workers.CleanupStale
        scheduler_module_name Magus.Agents.AgentRun.Schedulers.CleanupStale
        max_attempts 1
      end

      trigger :sweep_stuck_pending_runs do
        action :sweep_stuck_pending
        queue :agent_run_cleanup
        scheduler_cron "*/15 * * * *"
        read_action :stuck_pending_runs
        worker_read_action :stuck_pending_runs
        where expr(is_stuck_pending)
        worker_module_name Magus.Agents.AgentRun.Workers.SweepStuckPending
        scheduler_module_name Magus.Agents.AgentRun.Schedulers.SweepStuckPending
        max_attempts 1
      end

      trigger :prune_terminal_runs do
        action :prune
        queue :agent_run_retention
        scheduler_cron "40 4 * * *"
        read_action :prunable_runs
        worker_read_action :prunable_runs
        where expr(is_prunable)
        worker_module_name Magus.Agents.AgentRun.Workers.PruneTerminal
        scheduler_module_name Magus.Agents.AgentRun.Schedulers.PruneTerminal
        max_attempts 1
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :kind,
        :source,
        :source_conversation_id,
        :source_message_id,
        :source_event_id,
        :target_conversation_id,
        :target_agent_id,
        :initiator_user_id,
        :request_id,
        :idempotency_key,
        :model_key,
        :objective,
        :metadata,
        :task_id,
        :event_id
      ]
    end

    update :start do
      require_atomic? false

      change set_attribute(:status, :running)
      change set_attribute(:started_at, &DateTime.utc_now/0)
      change set_attribute(:last_heartbeat_at, &DateTime.utc_now/0)
    end

    update :heartbeat do
      require_atomic? false

      change set_attribute(:last_heartbeat_at, &DateTime.utc_now/0)
    end

    update :complete do
      require_atomic? false

      accept [:result_text]

      change set_attribute(:status, :complete)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
      change Magus.Agents.AgentRun.Changes.CalculateDuration
    end

    update :fail do
      require_atomic? false

      accept [:error_message]

      change set_attribute(:status, :error)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
      change Magus.Agents.AgentRun.Changes.CalculateDuration
    end

    update :exceed_budget do
      require_atomic? false

      accept [:result_text]

      change set_attribute(:status, :budget_exceeded)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
      change Magus.Agents.AgentRun.Changes.CalculateDuration
    end

    update :timeout do
      require_atomic? false

      change set_attribute(:status, :timed_out)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
      change Magus.Agents.AgentRun.Changes.CalculateDuration
    end

    update :cancel do
      require_atomic? false

      change set_attribute(:status, :cancelled)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
      change Magus.Agents.AgentRun.Changes.CalculateDuration
    end

    update :mark_delivered do
      require_atomic? false

      change set_attribute(:delivered_to_parent_at, &DateTime.utc_now/0)
    end

    update :requeue do
      require_atomic? false

      change set_attribute(:status, :pending)
      change set_attribute(:started_at, nil)
      change set_attribute(:last_heartbeat_at, nil)
    end

    update :cleanup_stale do
      description "Oban-triggered cleanup for stale runs"
      require_atomic? false
      transaction? false

      change Magus.Agents.AgentRun.Changes.CleanupStale
    end

    update :sweep_stuck_pending do
      description "Oban-triggered sweep for runs stuck in :pending"
      require_atomic? false
      transaction? false

      change Magus.Agents.AgentRun.Changes.SweepStuckPending
    end

    read :running_for_source do
      argument :source_conversation_id, :uuid, allow_nil?: false

      filter expr(
               source_conversation_id == ^arg(:source_conversation_id) and
                 status in [:pending, :running]
             )
    end

    read :running_for_target do
      argument :target_conversation_id, :uuid, allow_nil?: false

      filter expr(
               target_conversation_id == ^arg(:target_conversation_id) and
                 status in [:pending, :running]
             )

      prepare build(sort: [inserted_at: :asc])
    end

    read :stale_runs do
      pagination keyset?: true, required?: false
      filter expr(is_stale)
    end

    read :stuck_pending_runs do
      pagination keyset?: true, required?: false
      filter expr(status == :pending and inserted_at < ago(15, :minute))
    end

    read :prunable_runs do
      description """
      Terminal runs (complete/error/timed_out/cancelled/budget_exceeded)
      older than 90 days (measured on `updated_at`, the terminal-transition
      timestamp proxy). Backs the daily `:prune_terminal_runs` trigger.
      """

      pagination keyset?: true, required?: false
      filter expr(is_prunable)
    end

    destroy :prune do
      description "Oban-triggered retention destroy for a terminal run past its 90-day window"
      accept []
      require_atomic? false
    end
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    bypass action_type([:read, :create, :update, :destroy]) do
      authorize_if Magus.Checks.IsAiAgent
    end

    policy action_type(:read) do
      authorize_if expr(initiator_user_id == ^actor(:id))

      authorize_if expr(source_conversation.user_id == ^actor(:id))

      authorize_if expr(
                     exists(
                       source_conversation.members,
                       user_id == ^actor(:id) and not is_nil(accepted_at)
                     )
                   )

      authorize_if expr(
                     not is_nil(source_conversation.workspace_id) and
                       source_conversation.is_shared_to_workspace == true and
                       exists(
                         source_conversation.workspace.members,
                         is_active == true and user_id == ^actor(:id)
                       )
                   )

      authorize_if expr(
                     not is_nil(target_conversation_id) and
                       target_conversation.user_id == ^actor(:id)
                   )

      authorize_if expr(
                     not is_nil(target_conversation_id) and
                       exists(
                         target_conversation.members,
                         user_id == ^actor(:id) and not is_nil(accepted_at)
                       )
                   )

      authorize_if expr(
                     not is_nil(target_conversation_id) and
                       not is_nil(target_conversation.workspace_id) and
                       target_conversation.is_shared_to_workspace == true and
                       exists(
                         target_conversation.workspace.members,
                         is_active == true and user_id == ^actor(:id)
                       )
                   )
    end

    # AgentRun lifecycle (start/complete/fail/timeout/cancel/requeue/heartbeat)
    # and creation are exclusively server-side: the orchestrator, agent plugins,
    # and AI tools all call with `authorize?: false` (AshOban / IsAiAgent
    # bypasses above cover the agent-driven callers). Deny user-facing writes
    # until we intentionally expose a user-initiated control (e.g. cancel from
    # the control room), at which point we'll add a scoped policy.
    policy action_type([:create, :update, :destroy]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :kind, :atom do
      constraints one_of: [:consult, :delegate, :subtask]
      default :subtask
      allow_nil? false
      public? true
    end

    attribute :source, :atom do
      constraints one_of: [
                    :mention,
                    :heartbeat,
                    :manual_trigger,
                    :sub_agent_spawn,
                    :inbox_urgent
                  ]

      default :mention
      allow_nil? false
      public? true
      description "How the run was initiated. Drives budget enforcement and observability."
    end

    attribute :source_conversation_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :source_message_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :source_event_id, :string do
      allow_nil? true
      public? true
      description "Parent tool card event_id for step relay"
    end

    attribute :target_conversation_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :target_agent_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :initiator_user_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :request_id, :string do
      allow_nil? false
      public? true
    end

    attribute :idempotency_key, :string do
      allow_nil? true
      public? true
    end

    attribute :model_key, :string do
      allow_nil? true
      public? true
    end

    attribute :objective, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [
                    :pending,
                    :running,
                    :complete,
                    :error,
                    :timed_out,
                    :cancelled,
                    :budget_exceeded
                  ]

      default :pending
      allow_nil? false
      public? true
    end

    attribute :result_text, :string do
      allow_nil? true
      public? true
    end

    attribute :error_message, :string do
      allow_nil? true
      public? true
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :completed_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :last_heartbeat_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :duration_ms, :integer do
      allow_nil? true
      public? true
    end

    attribute :task_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :event_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :metadata, :map do
      default %{}
      public? true
    end

    attribute :delivered_to_parent_at, :utc_datetime_usec do
      allow_nil? true
      public? true

      description "When this run's result was delivered to the parent's LLM (set by await_sub_agents or SubAgentResumer)."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :source_conversation, Magus.Chat.Conversation do
      define_attribute? false
      source_attribute :source_conversation_id
      allow_nil? false
    end

    belongs_to :target_conversation, Magus.Chat.Conversation do
      define_attribute? false
      source_attribute :target_conversation_id
      allow_nil? true
    end

    belongs_to :target_agent, Magus.Agents.CustomAgent do
      define_attribute? false
      source_attribute :target_agent_id
      allow_nil? true
    end

    belongs_to :triggering_event, Magus.Agents.AgentInboxEvent do
      attribute_writable? true
      allow_nil? true
      define_attribute? false
      source_attribute :event_id
    end
  end

  calculations do
    calculate :is_stale, :boolean do
      calculation expr(
                    status == :running and
                      last_heartbeat_at < ago(2, :minute)
                  )
    end

    calculate :is_stuck_pending, :boolean do
      public? false

      calculation expr(
                    status == :pending and
                      inserted_at < ago(15, :minute)
                  )
    end

    calculate :is_prunable, :boolean do
      public? false

      calculation expr(
                    status in [:complete, :error, :timed_out, :cancelled, :budget_exceeded] and
                      updated_at < ago(90, :day)
                  )
    end
  end

  identities do
    identity :unique_idempotency_key, [:idempotency_key] do
      where expr(not is_nil(idempotency_key))
    end
  end
end
