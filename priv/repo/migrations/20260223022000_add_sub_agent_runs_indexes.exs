defmodule Magus.Repo.Migrations.AddSubAgentRunsIndexes do
  use Ecto.Migration

  def up do
    create index(:sub_agent_runs, [:parent_conversation_id, :status])
    create index(:sub_agent_runs, [:status, :last_heartbeat_at])
  end

  def down do
    drop index(:sub_agent_runs, [:parent_conversation_id, :status])
    drop index(:sub_agent_runs, [:status, :last_heartbeat_at])
  end
end
