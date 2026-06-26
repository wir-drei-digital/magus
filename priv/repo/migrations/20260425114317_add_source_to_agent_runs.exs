defmodule Magus.Repo.Migrations.AddSourceToAgentRuns do
  @moduledoc "Adds source enum and target_agent/source/inserted_at index to AgentRun for budget queries."

  use Ecto.Migration

  def up do
    alter table(:agent_runs) do
      add :source, :text, default: "mention"
    end

    create index(:agent_runs, [:target_agent_id, :source, :inserted_at],
             name: "agent_runs_target_agent_source_inserted_at_idx"
           )
  end

  def down do
    drop index(:agent_runs, [:target_agent_id, :source, :inserted_at],
           name: "agent_runs_target_agent_source_inserted_at_idx"
         )

    alter table(:agent_runs) do
      remove :source
    end
  end
end
