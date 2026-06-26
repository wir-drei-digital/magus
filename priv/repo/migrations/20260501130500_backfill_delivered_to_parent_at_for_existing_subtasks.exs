defmodule Magus.Repo.Migrations.BackfillDeliveredToParentAtForExistingSubtasks do
  use Ecto.Migration

  def up do
    execute """
    UPDATE agent_runs
    SET delivered_to_parent_at = NOW()
    WHERE kind = 'subtask'
      AND status IN ('complete', 'error', 'timed_out', 'cancelled')
      AND delivered_to_parent_at IS NULL
    """
  end

  def down do
    # No rollback — re-running with NULL would be unrecoverable.
    :ok
  end
end
