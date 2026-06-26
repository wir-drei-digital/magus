defmodule Magus.Repo.Migrations.ResetUserModelSelections do
  @moduledoc """
  One-time data migration to reset all user model selections to nil.

  This makes the auto-router the default for all users. Users who want
  explicit model defaults can set them in Settings.
  """

  use Ecto.Migration

  def up do
    execute """
    UPDATE users
    SET selected_model_id = NULL,
        selected_image_model_id = NULL,
        selected_video_model_id = NULL
    """
  end

  def down do
    # No rollback — previous selections are not recoverable
    :ok
  end
end
