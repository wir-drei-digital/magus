defmodule Magus.Repo.Migrations.CreateWorkflowsTables do
  @moduledoc """
  Creates the Workflows domain tables: jobs, job_runs, and job_notification_preferences.
  """

  use Ecto.Migration

  def change do
    create table(:jobs, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :name, :string, null: false
      add :description, :text
      add :trigger_prompt, :text, null: false
      add :memory_name, :string

      add :schedule_type, :string, null: false
      add :cron_expression, :string
      add :cron_expression_local, :string
      add :user_timezone, :string, default: "UTC"

      add :scheduled_at, :utc_datetime_usec

      add :starts_at, :utc_datetime_usec, null: false
      add :ends_at, :utc_datetime_usec

      add :status, :string, default: "active", null: false

      add :last_run_at, :utc_datetime_usec
      add :next_run_at, :utc_datetime_usec

      add :retry_count, :integer, default: 0
      add :max_retries, :integer, default: 3

      add :conversation_id,
          references(:conversations, type: :uuid, on_delete: :delete_all),
          null: false

      add :user_id,
          references(:users, type: :uuid, on_delete: :delete_all),
          null: false

      timestamps()
    end

    # Unique job name per conversation (only for non-stopped jobs)
    create unique_index(:jobs, [:conversation_id, :name], where: "status != 'stopped'")

    # Index for finding jobs by conversation
    create index(:jobs, [:conversation_id, :status])

    # Index for finding jobs by user
    create index(:jobs, [:user_id, :status])

    # Index for finding due jobs (used by scheduler)
    create index(:jobs, [:status, :next_run_at])

    create table(:job_runs, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :status, :string, default: "pending", null: false

      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      add :error_message, :text
      add :retry_attempt, :integer, default: 0

      add :metadata, :map, default: %{}

      add :job_id,
          references(:jobs, type: :uuid, on_delete: :delete_all),
          null: false

      add :trigger_message_id,
          references(:messages, type: :uuid, on_delete: :nilify_all)

      add :response_message_id,
          references(:messages, type: :uuid, on_delete: :nilify_all)

      add :inserted_at, :utc_datetime_usec, null: false
    end

    # Index for finding runs by job
    create index(:job_runs, [:job_id, :started_at])
    create index(:job_runs, [:job_id, :status])

    create table(:job_notification_preferences, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :notify_on_success, :boolean, default: false
      add :notify_on_failure, :boolean, default: true
      add :notification_channels, {:array, :string}, default: ["in_app"]

      add :job_id,
          references(:jobs, type: :uuid, on_delete: :delete_all),
          null: false
    end

    # One notification preference per job
    create unique_index(:job_notification_preferences, [:job_id])
  end
end
