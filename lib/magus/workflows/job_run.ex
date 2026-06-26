defmodule Magus.Workflows.JobRun do
  @moduledoc """
  Tracks individual execution runs of a Job.

  Each time a job is triggered, a JobRun record is created to track:
  - Execution status (pending, running, success, failed, retrying)
  - Timing information (started_at, completed_at)
  - Error details if the run failed
  - Links to trigger and response messages in the conversation
  """

  use Ash.Resource,
    otp_app: :magus,
    domain: Magus.Workflows,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshTypescript.Resource]

  require Ash.Query

  postgres do
    table "job_runs"
    repo Magus.Repo

    custom_indexes do
      # Indexes for message lookups - prevents slow message deletions
      index [:trigger_message_id]
      index [:response_message_id]
    end
  end

  typescript do
    type_name "JobRun"
  end

  actions do
    defaults [:read]

    create :create do
      accept [:metadata, :retry_attempt]
      argument :job_id, :uuid, allow_nil?: false

      change set_attribute(:job_id, arg(:job_id))
      change set_attribute(:status, :pending)
      change set_attribute(:started_at, &DateTime.utc_now/0)
    end

    update :start do
      change set_attribute(:status, :running)
      change set_attribute(:started_at, &DateTime.utc_now/0)
    end

    update :succeed do
      argument :response_message_id, :uuid

      change set_attribute(:status, :success)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
      change set_attribute(:response_message_id, arg(:response_message_id))
    end

    update :fail do
      argument :error_message, :string

      change set_attribute(:status, :failed)
      change set_attribute(:completed_at, &DateTime.utc_now/0)
      change set_attribute(:error_message, arg(:error_message))
    end

    update :retry do
      require_atomic? false

      change set_attribute(:status, :retrying)

      change fn changeset, _context ->
        current = Ash.Changeset.get_attribute(changeset, :retry_attempt) || 0
        Ash.Changeset.change_attribute(changeset, :retry_attempt, current + 1)
      end
    end

    update :set_trigger_message do
      argument :trigger_message_id, :uuid, allow_nil?: false
      change set_attribute(:trigger_message_id, arg(:trigger_message_id))
    end

    read :for_job do
      argument :job_id, :uuid, allow_nil?: false

      filter expr(job_id == ^arg(:job_id))
      prepare build(sort: [started_at: :desc])
    end

    read :recent_for_job do
      argument :job_id, :uuid, allow_nil?: false
      argument :limit, :integer, default: 10

      filter expr(job_id == ^arg(:job_id))
      prepare build(sort: [started_at: :desc])

      prepare fn query, _context ->
        limit_val = Ash.Query.get_argument(query, :limit)
        Ash.Query.limit(query, limit_val)
      end
    end
  end

  policies do
    # AshOban triggers bypass authorization
    bypass AshOban.Checks.AshObanInteraction do
      authorize_if always()
    end

    # AI Agent can manage job runs
    bypass action_type([:read, :create, :update]) do
      authorize_if Magus.Checks.IsAiAgent
    end

    # Users can read runs for their jobs
    policy action_type(:read) do
      authorize_if expr(exists(job, user_id == ^actor(:id)))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :status, :atom do
      constraints one_of: [:pending, :running, :success, :failed, :retrying]
      default :pending
      allow_nil? false
      public? true
    end

    attribute :started_at, :utc_datetime_usec, public?: true
    attribute :completed_at, :utc_datetime_usec, public?: true

    attribute :error_message, :string, public?: true
    attribute :retry_attempt, :integer, default: 0, public?: true

    attribute :metadata, :map, default: %{}, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :job, Magus.Workflows.Job, allow_nil?: false
    belongs_to :trigger_message, Magus.Chat.Message
    belongs_to :response_message, Magus.Chat.Message
  end
end
