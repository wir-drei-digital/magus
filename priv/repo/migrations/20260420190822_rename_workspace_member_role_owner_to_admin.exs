defmodule Magus.Repo.Migrations.RenameWorkspaceMemberRoleOwnerToAdmin do
  use Ecto.Migration

  def up do
    execute("UPDATE workspace_members SET role = 'admin' WHERE role = 'owner'")
  end

  def down do
    execute("UPDATE workspace_members SET role = 'owner' WHERE role = 'admin'")
  end
end
