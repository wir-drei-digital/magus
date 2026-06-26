defmodule Magus.Repo.Migrations.BackfillBrainAccessGrants do
  use Ecto.Migration

  def up, do: Magus.Workspaces.Backfill.BrainAccess.run()
  def down, do: :ok
end
