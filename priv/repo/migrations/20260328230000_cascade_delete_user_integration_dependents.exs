defmodule Magus.Repo.Migrations.CascadeDeleteUserIntegrationDependents do
  @moduledoc """
  Adds ON DELETE CASCADE to foreign keys referencing user_integrations.

  Without this, destroying a UserIntegration fails with a constraint error
  when input_messages, output_messages, integration_conversations, or
  ingestion_entries exist for that integration.
  """
  use Ecto.Migration

  def up do
    # Use raw SQL to swap FK constraints atomically.
    # Ecto's modify/from approach double-drops when combined with explicit drop.
    for {table, fk_name} <- [
          {"integration_input_messages", "integration_input_messages_user_integration_id_fkey"},
          {"integration_output_messages", "integration_output_messages_user_integration_id_fkey"},
          {"integration_conversations", "integration_conversations_user_integration_id_fkey"},
          {"integration_credentials", "integration_credentials_user_integration_id_fkey"},
          {"ingestion_entries", "ingestion_entries_user_integration_id_fkey"}
        ] do
      execute """
      ALTER TABLE #{table}
        DROP CONSTRAINT "#{fk_name}",
        ADD CONSTRAINT "#{fk_name}"
          FOREIGN KEY (user_integration_id)
          REFERENCES user_integrations(id)
          ON DELETE CASCADE
      """
    end
  end

  def down do
    for {table, fk_name} <- [
          {"integration_input_messages", "integration_input_messages_user_integration_id_fkey"},
          {"integration_output_messages", "integration_output_messages_user_integration_id_fkey"},
          {"integration_conversations", "integration_conversations_user_integration_id_fkey"},
          {"integration_credentials", "integration_credentials_user_integration_id_fkey"},
          {"ingestion_entries", "ingestion_entries_user_integration_id_fkey"}
        ] do
      execute """
      ALTER TABLE #{table}
        DROP CONSTRAINT "#{fk_name}",
        ADD CONSTRAINT "#{fk_name}"
          FOREIGN KEY (user_integration_id)
          REFERENCES user_integrations(id)
          ON DELETE RESTRICT
      """
    end
  end
end
