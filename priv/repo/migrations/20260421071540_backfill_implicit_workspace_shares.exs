defmodule Magus.Repo.Migrations.BackfillImplicitWorkspaceShares do
  use Ecto.Migration

  def up, do: Magus.Workspaces.Backfill.ImplicitWorkspaceShares.run()
  def down, do: :ok
end
