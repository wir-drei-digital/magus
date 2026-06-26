defmodule Magus.Repo.Migrations.InternalizeStaticExtras do
  use Ecto.Migration

  def up do
    Magus.Models.Backfill.run()
    Magus.Models.InternalizeExtras.run()
  end

  def down, do: :ok
end
