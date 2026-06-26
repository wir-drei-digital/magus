defmodule Magus.Repo.Migrations.BackfillModelProviders do
  use Ecto.Migration

  def up do
    Magus.Models.Backfill.run()
  end

  def down do
    :ok
  end
end
