defmodule Magus.Repo.Migrations.DropTriageModelIdFromCustomAgents do
  @moduledoc "Drops dead triage_model_id column from custom_agents (per-agent triage model override was schema-only, never read)."

  use Ecto.Migration

  def up do
    alter table(:custom_agents) do
      remove :triage_model_id
    end
  end

  def down do
    alter table(:custom_agents) do
      add :triage_model_id,
          references(:models,
            column: :id,
            name: "custom_agents_triage_model_id_fkey",
            type: :uuid,
            prefix: "public"
          )
    end
  end
end
