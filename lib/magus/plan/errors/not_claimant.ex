defmodule Magus.Plan.Errors.NotClaimant do
  @moduledoc """
  Returned by `:heartbeat` (and other claimant-gated verbs) when the caller is
  not the current claimant of the task, or the task is not `:in_progress`.

  Under the single-user posture several agents can share one token user, so the
  claimant is discriminated by the `--as` label (stored in `assigned_to_agent`),
  not the actor. This prevents agent B from keeping (or closing out) agent A's
  claim.

  Tagged `class: :invalid` (like `AlreadyClaimed`) so callers can pattern-match
  on `%Ash.Error.Invalid{errors: [%__MODULE__{} | _]}`.
  """

  use Splode.Error, fields: [:task_id], class: :invalid

  def message(%{task_id: task_id}), do: "caller is not the current claimant of task #{task_id}"
end
