defmodule Magus.Repo.Migrations.DropBrainAccessesTable do
  use Ecto.Migration

  def up do
    drop_if_exists table(:brain_accesses)
  end

  def down, do: :ok
end
