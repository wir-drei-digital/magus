defmodule Magus.Agents.AgentActivityLog do
  @moduledoc """
  Append-only audit log of agent actions and outcomes.

  Each record captures one unit of agent work: triage runs, event resolutions,
  task lifecycle changes, sub-agent spawns, approvals, and errors. Logs are
  immutable — there are no update actions.
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource, AshOban]

  postgres do
    table "agent_activity_logs"
    repo Magus.Repo
  end

  typescript do
    type_name "AgentActivityLog"
  end

  oban do
    triggers do
      trigger :prune_old_logs do
        action :prune
        queue :agent_activity_log_retention
        scheduler_cron "50 4 * * *"
        read_action :prunable
        worker_read_action :prunable
        where expr(is_prunable)
        worker_module_name Magus.Agents.AgentActivityLog.Workers.PruneOld
        scheduler_module_name Magus.Agents.AgentActivityLog.Schedulers.PruneOld
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
        :activity_type,
        :summary,
        :event_id,
        :run_id,
        :task_id,
        :conversation_id,
        :details,
        :model_used,
        :tokens_used,
        :estimated_cost_usd,
        :duration_ms
      ]

      change relate_actor(:user)

      change after_action(fn _changeset, record, _context ->
               Magus.Agents.ActivityBroadcaster.broadcast_activity(record)
               {:ok, record}
             end)
    end

    read :for_agent do
      argument :agent_id, :uuid, allow_nil?: false

      filter expr(agent_id == ^arg(:agent_id))

      prepare build(sort: [inserted_at: :desc], limit: 50, load: [:conversation])
    end

    read :for_user do
      argument :limit, :integer, default: 50
      argument :offset, :integer, default: 0

      filter expr(user_id == ^actor(:id))

      prepare build(sort: [inserted_at: :desc], load: [:conversation])

      prepare fn query, _context ->
        limit = Ash.Query.get_argument(query, :limit)
        offset = Ash.Query.get_argument(query, :offset)

        query
        |> Ash.Query.limit(limit + 1)
        |> Ash.Query.offset(offset)
      end
    end

    read :prunable do
      description """
      Logs older than 90 days (measured on `inserted_at`, since activity logs
      are append-only). Backs the daily `:prune_old_logs` trigger.
      """

      pagination keyset?: true, required?: false
      filter expr(is_prunable)
    end

    destroy :prune do
      description "Oban-triggered retention destroy for a log past its 90-day window"
      accept []
      require_atomic? false
    end
  end

  policies do
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    policy action_type(:create) do
      authorize_if actor_present()
    end

    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))
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

    attribute :activity_type, :atom do
      constraints one_of: [
                    :triage_completed,
                    :event_resolved,
                    :event_dismissed,
                    :task_created,
                    :task_updated,
                    :task_completed,
                    :run_spawned,
                    :run_completed,
                    :run_failed,
                    :approval_requested,
                    :response_sent,
                    :content_curated,
                    :memory_updated,
                    :external_tool_call,
                    :error,
                    :wake_skipped,
                    :wake_urgent,
                    :run_timed_out,
                    :recovery,
                    :watchdog_reset
                  ]

      allow_nil? false
      public? true
    end

    attribute :summary, :string do
      allow_nil? false
      public? true
    end

    attribute :event_id, :uuid do
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

    attribute :conversation_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :details, :map do
      default %{}
      public? true
    end

    attribute :model_used, :string do
      allow_nil? true
      public? true
    end

    attribute :tokens_used, :integer do
      allow_nil? true
      public? true
    end

    attribute :estimated_cost_usd, :decimal do
      allow_nil? true
      public? true
    end

    attribute :duration_ms, :integer do
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

    belongs_to :conversation, Magus.Chat.Conversation do
      define_attribute? false
      source_attribute :conversation_id
      allow_nil? true
    end
  end

  calculations do
    calculate :is_prunable, :boolean do
      public? false

      calculation expr(inserted_at < ago(90, :day))
    end
  end
end
