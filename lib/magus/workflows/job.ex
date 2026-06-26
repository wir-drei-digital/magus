defmodule Magus.Workflows.Job do
  @moduledoc """
  A scheduled workflow job that triggers AI agent actions.

  Jobs can be scheduled via cron expressions for recurring execution
  or as one-time scheduled tasks. Each job belongs to a conversation
  and triggers the agent with a specific prompt when executed.

  Features:
  - Cron-based scheduling for recurring tasks
  - One-time scheduled execution
  - Timezone-aware scheduling (cron stored in UTC)
  - Optional memory loading during execution
  - Pause/resume/stop lifecycle management
  - Retry logic with configurable max attempts
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Workflows,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshOban, AshTypescript.Resource],
    authorizers: [Ash.Policy.Authorizer]

  alias Oban.Cron.Expression

  require Ash.Query

  postgres do
    table "jobs"
    repo Magus.Repo

    identity_wheres_to_sql unique_name_per_conversation: "status != 'stopped'"
  end

  oban do
    triggers do
      trigger :execute_job do
        action :execute
        queue :workflow_jobs
        scheduler_cron "* * * * *"
        read_action :read
        worker_read_action :read
        where expr(due_for_execution)
        worker_module_name Magus.Workflows.Job.Workers.Execute
        scheduler_module_name Magus.Workflows.Job.Schedulers.Execute
        max_attempts 3
      end
    end
  end

  typescript do
    type_name "Job"
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
      pagination keyset?: true, required?: false
    end

    create :create do
      accept [
        :name,
        :description,
        :trigger_prompt,
        :memory_name,
        :schedule_type,
        :cron_expression,
        :cron_expression_local,
        :user_timezone,
        :scheduled_at,
        :starts_at,
        :ends_at,
        :user_id
      ]

      argument :conversation_id, :uuid, allow_nil?: false

      change set_attribute(:conversation_id, arg(:conversation_id))

      # Set user_id from actor if not provided explicitly (for AI agent tool calls)
      change fn changeset, context ->
        case Ash.Changeset.get_attribute(changeset, :user_id) do
          nil ->
            # Use actor as user if no user_id attribute set
            case context.actor do
              %Magus.Accounts.User{id: id} ->
                Ash.Changeset.change_attribute(changeset, :user_id, id)

              _ ->
                Ash.Changeset.add_error(changeset, field: :user_id, message: "is required")
            end

          _user_id ->
            # user_id already set, keep it
            changeset
        end
      end

      change fn changeset, _context ->
        # Default starts_at to now if not provided
        if is_nil(Ash.Changeset.get_attribute(changeset, :starts_at)) do
          Ash.Changeset.change_attribute(changeset, :starts_at, DateTime.utc_now())
        else
          changeset
        end
      end

      change Magus.Workflows.Job.Changes.ScheduleNextRun
    end

    update :update do
      require_atomic? false

      accept [
        :name,
        :description,
        :trigger_prompt,
        :memory_name,
        :cron_expression,
        :cron_expression_local,
        :starts_at,
        :ends_at
      ]

      change Magus.Workflows.Job.Changes.ScheduleNextRun
    end

    update :pause do
      require_atomic? false
      change set_attribute(:status, :paused)
    end

    update :resume do
      require_atomic? false
      change set_attribute(:status, :active)
      change Magus.Workflows.Job.Changes.ScheduleNextRun
    end

    update :stop do
      require_atomic? false
      change set_attribute(:status, :stopped)
    end

    update :complete do
      require_atomic? false
      change set_attribute(:status, :completed)
    end

    update :mark_run do
      require_atomic? false

      change set_attribute(:last_run_at, &DateTime.utc_now/0)

      change fn changeset, _context ->
        Ash.Changeset.change_attribute(changeset, :retry_count, 0)
      end

      change Magus.Workflows.Job.Changes.ScheduleNextRun
    end

    update :increment_retry do
      require_atomic? false

      change fn changeset, _context ->
        current = Ash.Changeset.get_attribute(changeset, :retry_count) || 0
        Ash.Changeset.change_attribute(changeset, :retry_count, current + 1)
      end
    end

    update :execute do
      description "Execute the job (triggered by AshOban scheduler)"
      require_atomic? false

      # transaction? false is intentional - job execution involves multiple
      # independent operations (create JobRun, create trigger message, update job).
      # Not wrapping in a transaction:
      # 1. Avoids holding DB locks during potentially slow message creation
      # 2. Allows partial progress to be recorded (JobRun tracks execution state)
      # 3. The Execute change handles failures by marking JobRun as failed
      # Trade-off: If system crashes mid-execution, JobRun may be orphaned in
      # pending/running state. Oban's retry mechanism will re-attempt execution.
      transaction? false

      change Magus.Workflows.Job.Changes.Execute
    end

    read :for_conversation do
      argument :conversation_id, :uuid, allow_nil?: false

      filter expr(conversation_id == ^arg(:conversation_id) and status != :stopped)
      prepare build(sort: [inserted_at: :desc])
    end

    read :all_for_conversation do
      description "List all jobs for a conversation including stopped jobs"
      argument :conversation_id, :uuid, allow_nil?: false

      filter expr(conversation_id == ^arg(:conversation_id))
      prepare build(sort: [inserted_at: :desc])
    end

    read :for_user do
      argument :user_id, :uuid, allow_nil?: false

      filter expr(user_id == ^arg(:user_id) and status != :stopped)
      prepare build(sort: [inserted_at: :desc])
    end

    read :due_for_execution do
      pagination keyset?: true, required?: false

      filter expr(due_for_execution)
    end
  end

  policies do
    # AshOban triggers bypass authorization
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # AI Agent can access jobs for execution and create via tools.
    # Security note: This bypass grants broad access, but the actual tool implementations
    # (CreateJob, UpdateJob, etc.) always scope operations by conversation_id from context.
    # The tools only accept conversation-scoped operations - they never expose arbitrary job access.
    # Job IDs are never passed directly to tools; jobs are always looked up by name within a conversation.
    bypass action_type([:read, :create, :update]) do
      authorize_if Magus.Checks.IsAiAgent
    end

    # Users can read jobs they own, or jobs in conversations they are part of
    policy action_type(:read) do
      authorize_if expr(user_id == ^actor(:id))

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

    # Users can create jobs only in conversations they are members of
    policy action_type(:create) do
      authorize_if Magus.Workflows.Job.Checks.IsConversationMember
    end

    # Only the owner can modify jobs
    policy action_type([:update, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  changes do
    change Magus.Workflows.Job.Changes.ScheduleNextRun, on: [:create, :update]
  end

  validations do
    # Cron jobs require a cron expression
    validate fn changeset, _context ->
      schedule_type = Ash.Changeset.get_attribute(changeset, :schedule_type)
      cron = Ash.Changeset.get_attribute(changeset, :cron_expression)

      if schedule_type == :cron and is_nil(cron) do
        {:error, field: :cron_expression, message: "required for cron jobs"}
      else
        :ok
      end
    end

    # One-time jobs require a scheduled_at time
    validate fn changeset, _context ->
      schedule_type = Ash.Changeset.get_attribute(changeset, :schedule_type)
      scheduled_at = Ash.Changeset.get_attribute(changeset, :scheduled_at)

      if schedule_type == :one_time and is_nil(scheduled_at) do
        {:error, field: :scheduled_at, message: "required for one-time jobs"}
      else
        :ok
      end
    end

    # Cron jobs require an ends_at to prevent indefinite runs
    validate fn changeset, _context ->
      schedule_type = Ash.Changeset.get_attribute(changeset, :schedule_type)
      ends_at = Ash.Changeset.get_attribute(changeset, :ends_at)

      if schedule_type == :cron and is_nil(ends_at) do
        {:error, field: :ends_at, message: "required for cron jobs to prevent indefinite runs"}
      else
        :ok
      end
    end

    # Validate cron expression syntax
    validate fn changeset, _context ->
      cron = Ash.Changeset.get_attribute(changeset, :cron_expression)

      if cron do
        case Expression.parse(cron) do
          {:ok, _} -> :ok
          {:error, _} -> {:error, field: :cron_expression, message: "invalid cron expression"}
        end
      else
        :ok
      end
    end

    # Validate ends_at is in the future
    validate fn changeset, _context ->
      ends_at = Ash.Changeset.get_attribute(changeset, :ends_at)

      if ends_at && DateTime.compare(ends_at, DateTime.utc_now()) != :gt do
        {:error, field: :ends_at, message: "must be in the future"}
      else
        :ok
      end
    end

    # Validate ends_at is after starts_at
    validate fn changeset, _context ->
      ends_at = Ash.Changeset.get_attribute(changeset, :ends_at)
      starts_at = Ash.Changeset.get_attribute(changeset, :starts_at)

      if ends_at && starts_at && DateTime.compare(ends_at, starts_at) != :gt do
        {:error, field: :ends_at, message: "must be after starts_at"}
      else
        :ok
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :description, :string, public?: true
    attribute :trigger_prompt, :string, allow_nil?: false, public?: true
    attribute :memory_name, :string, public?: true

    attribute :schedule_type, :atom do
      constraints one_of: [:cron, :one_time]
      allow_nil? false
      public? true
    end

    attribute :cron_expression, :string, public?: true
    attribute :cron_expression_local, :string, public?: true
    attribute :user_timezone, :string, default: "UTC", public?: true

    attribute :scheduled_at, :utc_datetime_usec, public?: true

    attribute :starts_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :ends_at, :utc_datetime_usec, public?: true

    attribute :status, :atom do
      constraints one_of: [:active, :paused, :stopped, :completed]
      default :active
      allow_nil? false
      public? true
    end

    attribute :last_run_at, :utc_datetime_usec, public?: true
    attribute :next_run_at, :utc_datetime_usec, public?: true

    attribute :retry_count, :integer, default: 0
    attribute :max_retries, :integer, default: 3

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    # Public so the SPA /jobs detail can select `conversationId` for its
    # "open chat" link (jobs span conversations in the user-level view).
    belongs_to :conversation, Magus.Chat.Conversation do
      allow_nil? false
      public? true
    end

    belongs_to :user, Magus.Accounts.User, allow_nil?: false

    has_many :runs, Magus.Workflows.JobRun
    has_one :notification_preference, Magus.Workflows.NotificationPreference
  end

  calculations do
    calculate :due_for_execution, :boolean do
      # Use now() which evaluates at query time, not ^DateTime.utc_now() which
      # would be evaluated at compile time
      calculation expr(
                    status == :active and
                      next_run_at <= now() and
                      (is_nil(ends_at) or ends_at > now())
                  )
    end
  end

  identities do
    identity :unique_name_per_conversation, [:conversation_id, :name],
      where: expr(status != :stopped)
  end
end
