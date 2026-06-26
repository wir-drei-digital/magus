defmodule Magus.Repo.Migrations.TightenAgentRunSourceNotNull do
  @moduledoc "Tightens AgentRun source to NOT NULL so raw SQL inserts cannot bypass the default."

  use Ecto.Migration

  def up do
    alter table(:agent_runs) do
      modify :source, :text, null: false
    end
  end

  def down do
    alter table(:agent_runs) do
      modify :source, :text, null: true
    end
  end
end
