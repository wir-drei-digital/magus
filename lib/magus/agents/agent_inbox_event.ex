defmodule Magus.Agents.AgentInboxEvent do
  @moduledoc """
  Represents an incoming event for a custom agent's inbox.

  Agents receive events from multiple sources (mentions, task assignments,
  approval responses, heartbeats, integrations, etc.) and triage them
  to decide what action to take.

  Lifecycle: pending -> processing -> resolved | dismissed | expired
             pending -> waiting (blocked on subtask) -> resolved
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource, AshOban]

  postgres do
    table "agent_inbox_events"
    repo Magus.Repo

    references do
      reference :agent_run, on_delete: :nilify
    end

    identity_wheres_to_sql unique_idempotency:
                             "idempotency_key IS NOT NULL AND status IN ('pending', 'waiting', 'processing')",
                           unique_content_hash: "content_hash IS NOT NULL"
  end

  typescript do
    type_name "AgentInboxEvent"
  end

  oban do
    triggers do
      trigger :expire_due_events do
        action :expire
        queue :agent_inbox_event_retention
        scheduler_cron "0 * * * *"
        read_action :expiry_due
        worker_read_action :expiry_due
        where expr(is_expiry_due)
        worker_module_name Magus.Agents.AgentInboxEvent.Workers.ExpireDue
        scheduler_module_name Magus.Agents.AgentInboxEvent.Schedulers.ExpireDue
        max_attempts 1
      end

      trigger :prune_terminal_events do
        action :prune
        queue :agent_inbox_event_retention
        scheduler_cron "30 4 * * *"
        read_action :prunable
        worker_read_action :prunable
        where expr(is_prunable)
        worker_module_name Magus.Agents.AgentInboxEvent.Workers.PruneTerminal
        scheduler_module_name Magus.Agents.AgentInboxEvent.Schedulers.PruneTerminal
        max_attempts 1
      end
    end
  end

  actions do
    read :read do
      primary? true
    end

    create :create do
      accept [
        :agent_id,
        :event_type,
        :urgency,
        :title,
        :summary,
        :payload,
        :source_type,
        :source_id,
        :source_url,
        :content_hash,
        :idempotency_key,
        :metadata,
        :expires_at,
        :agent_run_id
      ]

      change relate_actor(:user)

      change after_action(fn _changeset, record, _context ->
               Magus.Agents.ActivityBroadcaster.broadcast_inbox_changed(
                 record.agent_id,
                 record.user_id
               )

               {:ok, record}
             end)

      change Magus.Agents.AgentInboxEvent.Changes.TriggerUrgentWake
    end

    update :start_processing do
      require_atomic? false
      change set_attribute(:status, :processing)
    end

    update :resolve do
      require_atomic? false
      accept [:resolved_by, :resolution_note, :run_id, :task_id]
      change set_attribute(:status, :resolved)
      change set_attribute(:resolved_at, &DateTime.utc_now/0)

      change after_action(fn _changeset, record, _context ->
               Magus.Agents.ActivityBroadcaster.broadcast_inbox_changed(
                 record.agent_id,
                 record.user_id
               )

               {:ok, record}
             end)
    end

    update :dismiss do
      require_atomic? false
      accept [:resolution_note]
      validate attribute_in(:status, [:pending, :waiting, :processing])
      change set_attribute(:status, :dismissed)
      change set_attribute(:resolved_at, &DateTime.utc_now/0)
      change set_attribute(:resolved_by, :user)

      change after_action(fn _changeset, record, _context ->
               Magus.Agents.ActivityBroadcaster.broadcast_inbox_changed(
                 record.agent_id,
                 record.user_id
               )

               {:ok, record}
             end)
    end

    update :dismiss_by_agent do
      require_atomic? false
      accept [:resolution_note]
      validate attribute_in(:status, [:pending, :waiting, :processing])
      change set_attribute(:status, :dismissed)
      change set_attribute(:resolved_at, &DateTime.utc_now/0)
      change set_attribute(:resolved_by, :agent)

      change after_action(fn _changeset, record, _context ->
               Magus.Agents.ActivityBroadcaster.broadcast_inbox_changed(
                 record.agent_id,
                 record.user_id
               )

               {:ok, record}
             end)
    end

    update :mark_waiting do
      require_atomic? false
      accept [:task_id]
      change set_attribute(:status, :waiting)

      change after_action(fn _changeset, record, _context ->
               Magus.Agents.ActivityBroadcaster.broadcast_inbox_changed(
                 record.agent_id,
                 record.user_id
               )

               {:ok, record}
             end)
    end

    update :expire do
      require_atomic? false
      change set_attribute(:status, :expired)
      change set_attribute(:resolved_at, &DateTime.utc_now/0)
      change set_attribute(:resolved_by, :expiry)

      change after_action(fn _changeset, record, _context ->
               Magus.Agents.ActivityBroadcaster.broadcast_inbox_changed(
                 record.agent_id,
                 record.user_id
               )

               {:ok, record}
             end)
    end

    update :link_to_run do
      require_atomic? false
      argument :run_id, :uuid, allow_nil?: false
      validate attribute_in(:status, [:pending, :waiting, :processing])
      change set_attribute(:agent_run_id, arg(:run_id))
    end

    update :unlink_from_run do
      require_atomic? false
      change set_attribute(:agent_run_id, nil)
    end

    update :resolve_via_run do
      require_atomic? false
      validate attribute_in(:status, [:pending, :waiting, :processing])
      change set_attribute(:status, :resolved)
      change set_attribute(:resolved_at, &DateTime.utc_now/0)
      change set_attribute(:resolved_by, :run_completed)

      change after_action(fn _changeset, record, _context ->
               Magus.Agents.ActivityBroadcaster.broadcast_inbox_changed(
                 record.agent_id,
                 record.user_id
               )

               {:ok, record}
             end)
    end

    read :pending_for_agent do
      argument :agent_id, :uuid, allow_nil?: false

      filter expr(
               agent_id == ^arg(:agent_id) and
                 status in [:pending, :waiting]
             )

      prepare build(sort: [urgency: :desc, inserted_at: :asc], limit: 50)
    end

    read :for_agent do
      argument :agent_id, :uuid, allow_nil?: false

      filter expr(agent_id == ^arg(:agent_id))

      prepare build(sort: [inserted_at: :desc], limit: 100)
    end

    create :create_waiting do
      accept [
        :agent_id,
        :event_type,
        :urgency,
        :title,
        :summary,
        :payload,
        :source_type,
        :source_id,
        :source_url,
        :content_hash,
        :idempotency_key,
        :metadata,
        :expires_at
      ]

      change set_attribute(:status, :waiting)
      change relate_actor(:user)

      change after_action(fn _changeset, record, _context ->
               Magus.Agents.ActivityBroadcaster.broadcast_inbox_changed(
                 record.agent_id,
                 record.user_id
               )

               {:ok, record}
             end)
    end

    read :by_idempotency_key do
      argument :idempotency_key, :string, allow_nil?: false
      filter expr(idempotency_key == ^arg(:idempotency_key))
      prepare build(limit: 1)
    end

    read :waiting_approval_for_conversation do
      argument :conversation_id, :string, allow_nil?: false

      filter expr(
               status == :waiting and
                 event_type == :approval_response and
                 source_id == ^arg(:conversation_id)
             )

      prepare build(sort: [inserted_at: :desc], limit: 1)
    end

    read :expiry_due do
      description """
      Events past their `expires_at` while still in a non-terminal status.
      Backs the hourly `:expire_due_events` trigger.
      """

      pagination keyset?: true, required?: false
      filter expr(is_expiry_due)
    end

    read :prunable do
      description """
      Terminal (resolved/dismissed/expired) events older than 30 days
      (measured on `updated_at`, the terminal-transition timestamp proxy).
      Backs the daily `:prune_terminal_events` trigger.
      """

      pagination keyset?: true, required?: false
      filter expr(is_prunable)
    end

    destroy :prune do
      description "Oban-triggered retention destroy for a terminal event past its 30-day window"
      accept []
      require_atomic? false
    end
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # AI agents acting on behalf of users can read/update events
    # (used by autonomous tools like ListInboxEvents).
    bypass action_type([:read, :update]) do
      authorize_if Magus.Checks.IsAiAgent
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type([:read, :update, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
      # The inbox belongs to the agent: events created on behalf of OTHER
      # actors (task assignments, integrations) must still be readable and
      # dismissable by the agent's owner.
      authorize_if expr(exists(agent, user_id == ^actor(:id)))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :agent_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :user_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :event_type, :atom do
      constraints one_of: [
                    :mention,
                    :task_assigned,
                    :approval_response,
                    :content,
                    :heartbeat,
                    :integration,
                    :agent_message,
                    :system
                  ]

      allow_nil? false
      public? true
    end

    attribute :urgency, :atom do
      constraints one_of: [:immediate, :deferred]
      default :deferred
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:pending, :processing, :waiting, :resolved, :dismissed, :expired]
      default :pending
      allow_nil? false
      public? true
    end

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :summary, :string do
      allow_nil? true
      public? true
    end

    attribute :payload, :map do
      default %{}
      public? true
    end

    attribute :source_type, :atom do
      constraints one_of: [:conversation, :integration, :scheduler, :agent, :system]
      allow_nil? false
      public? true
    end

    attribute :source_id, :string do
      allow_nil? true
      public? true
    end

    attribute :source_url, :string do
      allow_nil? true
      public? true
    end

    attribute :content_hash, :string do
      allow_nil? true
      public? true
    end

    attribute :idempotency_key, :string do
      allow_nil? true
      public? true
    end

    attribute :resolved_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :resolved_by, :atom do
      constraints one_of: [:triage, :agent, :user, :expiry, :system, :run_completed]
      allow_nil? true
      public? true
    end

    attribute :resolution_note, :string do
      allow_nil? true
      public? true
    end

    attribute :run_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :task_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :metadata, :map do
      default %{}
      public? true
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :agent, Magus.Agents.CustomAgent do
      define_attribute? false
      source_attribute :agent_id
      allow_nil? false
    end

    belongs_to :user, Magus.Accounts.User do
      define_attribute? false
      source_attribute :user_id
      allow_nil? false
    end

    belongs_to :agent_run, Magus.Agents.AgentRun do
      allow_nil? true
      public? true

      description "The AgentRun currently handling this event. Cleared on run failure; event marked resolved on run success."
    end
  end

  calculations do
    calculate :is_expiry_due, :boolean do
      public? false

      calculation expr(
                    not is_nil(expires_at) and expires_at < now() and
                      status in [:pending, :waiting, :processing]
                  )
    end

    calculate :is_prunable, :boolean do
      public? false

      calculation expr(status in [:resolved, :dismissed, :expired] and updated_at < ago(30, :day))
    end
  end

  identities do
    identity :unique_idempotency, [:agent_id, :idempotency_key] do
      where expr(not is_nil(idempotency_key) and status in [:pending, :waiting, :processing])
    end

    identity :unique_content_hash, [:agent_id, :content_hash] do
      where expr(not is_nil(content_hash))
    end
  end
end
