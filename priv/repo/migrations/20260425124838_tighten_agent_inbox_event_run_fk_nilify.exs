defmodule Magus.Repo.Migrations.TightenAgentInboxEventRunFkNilify do
  @moduledoc "Tightens AgentInboxEvent.agent_run_id FK to ON DELETE SET NULL so deleted runs nilify links instead of restricting deletes."

  use Ecto.Migration

  def up do
    drop constraint(:agent_inbox_events, "agent_inbox_events_agent_run_id_fkey")

    alter table(:agent_inbox_events) do
      modify :agent_run_id,
             references(:agent_runs,
               column: :id,
               name: "agent_inbox_events_agent_run_id_fkey",
               type: :uuid,
               prefix: "public",
               on_delete: :nilify_all
             )
    end
  end

  def down do
    drop constraint(:agent_inbox_events, "agent_inbox_events_agent_run_id_fkey")

    alter table(:agent_inbox_events) do
      modify :agent_run_id,
             references(:agent_runs,
               column: :id,
               name: "agent_inbox_events_agent_run_id_fkey",
               type: :uuid,
               prefix: "public"
             )
    end
  end
end
