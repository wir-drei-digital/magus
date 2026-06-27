defmodule Magus.Plan.Task.Changes.VerifyClaimant do
  @moduledoc """
  Guards a claimant-gated action (`:heartbeat`). The action carries an `:as`
  argument: the label the caller claims to own the task under. The task must be
  `:in_progress` AND its `assigned_to_agent` must equal `:as`, otherwise a
  `Magus.Plan.Errors.NotClaimant` error is added (rolling the action back).

  Compares against the already-loaded `changeset.data` (the action is invoked on
  a fetched record), so no extra read is needed.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    as = Ash.Changeset.get_argument(changeset, :as)
    task = changeset.data

    if task.status == :in_progress and task.assigned_to_agent == as do
      changeset
    else
      Ash.Changeset.add_error(
        changeset,
        Magus.Plan.Errors.NotClaimant.exception(task_id: task.id)
      )
    end
  end
end
