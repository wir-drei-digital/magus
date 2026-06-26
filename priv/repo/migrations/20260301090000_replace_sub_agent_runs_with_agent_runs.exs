defmodule Magus.Repo.Migrations.ReplaceSubAgentRunsWithAgentRuns do
  use Ecto.Migration

  def up do
    drop_if_exists index(:sub_agent_runs, [:parent_conversation_id, :status])
    drop_if_exists index(:sub_agent_runs, [:status, :last_heartbeat_at])

    drop_if_exists constraint(:sub_agent_runs, "sub_agent_runs_parent_conversation_id_fkey")
    drop_if_exists constraint(:sub_agent_runs, "sub_agent_runs_child_conversation_id_fkey")
    drop_if_exists constraint(:sub_agent_runs, "sub_agent_runs_custom_agent_id_fkey")

    drop_if_exists table(:sub_agent_runs)

    create table(:agent_runs, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true

      add :kind, :text, null: false, default: "subtask"

      add :source_conversation_id,
          references(:conversations,
            column: :id,
            name: "agent_runs_source_conversation_id_fkey",
            type: :uuid,
            prefix: "public"
          ),
          null: false

      add :source_message_id, :uuid

      add :target_conversation_id,
          references(:conversations,
            column: :id,
            name: "agent_runs_target_conversation_id_fkey",
            type: :uuid,
            prefix: "public"
          )

      add :target_agent_id,
          references(:custom_agents,
            column: :id,
            name: "agent_runs_target_agent_id_fkey",
            type: :uuid,
            prefix: "public"
          )

      add :initiator_user_id, :uuid
      add :request_id, :text, null: false
      add :idempotency_key, :text
      add :model_key, :text
      add :objective, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :result_text, :text
      add :error_message, :text
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :last_heartbeat_at, :utc_datetime_usec
      add :duration_ms, :bigint
      add :metadata, :map, default: %{}

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:agent_runs, [:source_conversation_id, :status])
    create index(:agent_runs, [:target_conversation_id, :status])
    create index(:agent_runs, [:status, :last_heartbeat_at])
    create unique_index(:agent_runs, [:request_id])
    create unique_index(:agent_runs, [:idempotency_key], where: "idempotency_key IS NOT NULL")
  end

  def down do
    drop_if_exists index(:agent_runs, [:source_conversation_id, :status])
    drop_if_exists index(:agent_runs, [:target_conversation_id, :status])
    drop_if_exists index(:agent_runs, [:status, :last_heartbeat_at])
    drop_if_exists index(:agent_runs, [:request_id])
    drop_if_exists index(:agent_runs, [:idempotency_key])

    drop_if_exists constraint(:agent_runs, "agent_runs_source_conversation_id_fkey")
    drop_if_exists constraint(:agent_runs, "agent_runs_target_conversation_id_fkey")
    drop_if_exists constraint(:agent_runs, "agent_runs_target_agent_id_fkey")

    drop_if_exists table(:agent_runs)

    create table(:sub_agent_runs, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuid_generate_v7()"), primary_key: true
      add :parent_conversation_id, :uuid, null: false
      add :child_conversation_id, :uuid
      add :custom_agent_id, :uuid
      add :model_key, :text, null: false
      add :objective, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :result_text, :text
      add :error_message, :text
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :last_heartbeat_at, :utc_datetime_usec
      add :duration_ms, :bigint
      add :metadata, :map, default: %{}

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:sub_agent_runs, [:parent_conversation_id, :status])
    create index(:sub_agent_runs, [:status, :last_heartbeat_at])
  end
end
