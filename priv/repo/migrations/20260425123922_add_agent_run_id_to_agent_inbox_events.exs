defmodule Magus.Repo.Migrations.AddAgentRunIdToAgentInboxEvents do
  @moduledoc "Adds nullable agent_run_id FK and index to AgentInboxEvent for run-linked event lifecycle."

  use Ecto.Migration

  def up do
    alter table(:agent_inbox_events) do
      add :agent_run_id,
          references(:agent_runs,
            column: :id,
            name: "agent_inbox_events_agent_run_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end

    create index(:agent_inbox_events, [:agent_run_id],
             name: "agent_inbox_events_agent_run_id_idx"
           )
  end

  def down do
    drop index(:agent_inbox_events, [:agent_run_id], name: "agent_inbox_events_agent_run_id_idx")

    drop constraint(:agent_inbox_events, "agent_inbox_events_agent_run_id_fkey")

    alter table(:agent_inbox_events) do
      remove :agent_run_id
    end
  end
end
