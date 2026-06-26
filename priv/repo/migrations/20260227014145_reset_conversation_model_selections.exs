defmodule Magus.Repo.Migrations.ResetConversationModelSelections do
  @moduledoc """
  One-time data migration to reset all conversation model selections to nil.

  Existing conversations had models pinned from the old dual-write behavior.
  Clearing them lets the auto-router take over for all model types.
  """

  use Ecto.Migration

  def up do
    execute """
    UPDATE conversations
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
