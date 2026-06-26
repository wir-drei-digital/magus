defmodule Magus.Repo.Migrations.AddMissingFkIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # Create indexes concurrently to avoid locking tables in production
    create_if_not_exists index(:sessions, [:model_id], concurrently: true)
    create_if_not_exists index(:sessions, [:workspace_id], concurrently: true)
    create_if_not_exists index(:sandbox_uploads, [:sandbox_id], concurrently: true)
    create_if_not_exists index(:conversation_favorites, [:conversation_id], concurrently: true)
    create_if_not_exists index(:workspace_members, [:user_id], concurrently: true)
    create_if_not_exists index(:prompts_versions, [:user_id], concurrently: true)
    create_if_not_exists index(:user_usage_overrides, [:user_id], concurrently: true)
    create_if_not_exists index(:conversation_events, [:user_id], concurrently: true)
    create_if_not_exists index(:folders, [:user_id], concurrently: true)
    create_if_not_exists index(:conversation_share_links, [:conversation_id], concurrently: true)
    create_if_not_exists index(:user_folder_states, [:folder_id], concurrently: true)
    create_if_not_exists index(:user_subscriptions_versions, [:user_id], concurrently: true)
    create_if_not_exists index(:conversations, [:folder_id], concurrently: true)
    create_if_not_exists index(:conversations, [:user_id], concurrently: true)
    create_if_not_exists index(:conversation_contexts, [:conversation_id], concurrently: true)
    create_if_not_exists index(:prompts, [:user_id], concurrently: true)
    create_if_not_exists index(:sandbox_executions, [:message_id], concurrently: true)
    create_if_not_exists index(:sandbox_executions, [:sandbox_id], concurrently: true)
    create_if_not_exists index(:message_usages, [:model_id], concurrently: true)
    create_if_not_exists index(:message_usages, [:conversation_id], concurrently: true)
    create_if_not_exists index(:message_usages, [:message_id], concurrently: true)
    create_if_not_exists index(:messages, [:conversation_id], concurrently: true)
  end
end
