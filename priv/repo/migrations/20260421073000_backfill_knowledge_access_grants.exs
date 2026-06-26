defmodule Magus.Repo.Migrations.BackfillKnowledgeAccessGrants do
  use Ecto.Migration

  def up, do: Magus.Workspaces.Backfill.KnowledgeAccess.run()
  def down, do: :ok
end
