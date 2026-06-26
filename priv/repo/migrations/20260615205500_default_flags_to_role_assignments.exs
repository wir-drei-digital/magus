defmodule Magus.Repo.Migrations.DefaultFlagsToRoleAssignments do
  use Ecto.Migration

  # Migrate the legacy default?/default_image?/default_video? boolean flags
  # into RoleAssignment rows (:chat_default / :image_default / :video_t2v).
  # Must run BEFORE the schema migration that drops those columns.
  def up do
    Magus.Models.DefaultFlagsBackfill.run()
  end

  def down, do: :ok
end
