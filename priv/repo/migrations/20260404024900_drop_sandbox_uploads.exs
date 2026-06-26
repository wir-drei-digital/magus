defmodule Magus.Repo.Migrations.DropSandboxUploads do
  use Ecto.Migration

  def up do
    drop_if_exists table(:sandbox_uploads)
  end

  def down do
    # Not recreating - this table was unused
    :ok
  end
end
