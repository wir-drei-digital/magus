defmodule Magus.Plan.Errors.AlreadyClaimed do
  @moduledoc """
  Returned by `Magus.Plan.Task.Changes.ClaimTask` when a task is claimed by
  someone else between the read and the claim. The advisory-locked re-read in
  `ClaimTask` finds the row no longer claimable and adds this error.

  Tagged `class: :invalid` (same as `VersionConflict`) so callers can
  pattern-match on `%Ash.Error.Invalid{errors: [%__MODULE__{} | _]}` and the
  API/CLI can return "already taken" without string-matching the message.
  """

  use Splode.Error, fields: [:task_id], class: :invalid

  def message(%{task_id: task_id}), do: "task #{task_id} is already claimed"
end
