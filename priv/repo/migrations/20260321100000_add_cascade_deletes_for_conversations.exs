defmodule Magus.Repo.Migrations.AddCascadeDeletesForConversations do
  @moduledoc """
  Adds proper ON DELETE CASCADE/SET NULL rules to foreign keys referencing
  conversations, messages, memories, and sandboxes. This allows the DB to
  handle cascading cleanup automatically, simplifying DeleteFullConversation.
  """
  use Ecto.Migration

  @cascade_fks [
    # {table, column, constraint_name, ref_table, on_delete}

    # conversations → ...
    {"messages", "conversation_id", "messages_conversation_id_fkey", "conversations", "CASCADE"},
    {"drafts", "conversation_id", "drafts_conversation_id_fkey", "conversations", "CASCADE"},
    {"files", "conversation_id", "memory_resources_conversation_id_fkey", "conversations",
     "CASCADE"},
    {"sandboxes", "conversation_id", "sandboxes_conversation_id_fkey", "conversations",
     "CASCADE"},
    {"conversation_contexts", "conversation_id", "conversation_contexts_conversation_id_fkey",
     "conversations", "CASCADE"},
    {"integration_conversations", "conversation_id",
     "integration_conversations_conversation_id_fkey", "conversations", "CASCADE"},
    {"agent_runs", "source_conversation_id", "agent_runs_source_conversation_id_fkey",
     "conversations", "CASCADE"},
    {"agent_runs", "target_conversation_id", "agent_runs_target_conversation_id_fkey",
     "conversations", "CASCADE"},
    {"plan_task_pane_states", "conversation_id", "plan_task_pane_states_conversation_id_fkey",
     "conversations", "CASCADE"},
    {"conversations", "parent_conversation_id", "conversations_parent_conversation_id_fkey",
     "conversations", "CASCADE"},
    {"integration_input_messages", "routed_to_conversation_id",
     "integration_input_messages_routed_to_conversation_id_fkey", "conversations", "SET NULL"},
    {"user_integrations", "conversation_id", "user_integrations_conversation_id_fkey",
     "conversations", "SET NULL"},

    # messages → ...
    {"messages", "response_to_id", "messages_response_to_id_fkey", "messages", "SET NULL"},
    {"conversation_contexts", "checkpoint_message_id",
     "conversation_contexts_checkpoint_message_id_fkey", "messages", "CASCADE"},
    {"sandbox_executions", "message_id", "sandbox_executions_message_id_fkey", "messages",
     "SET NULL"},

    # memories → ...
    {"memory_associations", "memory_a_id", "memory_associations_memory_a_id_fkey", "memories",
     "CASCADE"},
    {"memory_associations", "memory_b_id", "memory_associations_memory_b_id_fkey", "memories",
     "CASCADE"},
    {"memory_sources", "memory_id", "memory_sources_memory_id_fkey", "memories", "CASCADE"},

    # sandboxes → ...
    {"sandbox_executions", "sandbox_id", "sandbox_executions_sandbox_id_fkey", "sandboxes",
     "CASCADE"},
    {"sandbox_uploads", "sandbox_id", "sandbox_uploads_sandbox_id_fkey", "sandboxes", "CASCADE"}
  ]

  def up do
    for {table, column, constraint, ref_table, on_delete} <- @cascade_fks do
      execute """
      ALTER TABLE #{table}
        DROP CONSTRAINT #{constraint},
        ADD CONSTRAINT #{constraint}
          FOREIGN KEY (#{column}) REFERENCES #{ref_table}(id)
          ON DELETE #{on_delete}
      """
    end
  end

  def down do
    for {table, column, constraint, ref_table, _on_delete} <- @cascade_fks do
      execute """
      ALTER TABLE #{table}
        DROP CONSTRAINT #{constraint},
        ADD CONSTRAINT #{constraint}
          FOREIGN KEY (#{column}) REFERENCES #{ref_table}(id)
          ON DELETE NO ACTION
      """
    end
  end
end
