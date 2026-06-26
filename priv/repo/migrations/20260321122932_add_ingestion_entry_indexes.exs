defmodule Magus.Repo.Migrations.AddIngestionEntryIndexes do
  use Ecto.Migration

  def change do
    create index(:ingestion_entries, [:user_integration_id, :occurred_at])
    create index(:ingestion_entries, [:user_id, :source_type, :occurred_at])
  end
end
