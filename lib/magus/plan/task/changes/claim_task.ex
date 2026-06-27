defmodule Magus.Plan.Task.Changes.ClaimTask do
  @moduledoc """
  Atomically guards a task claim. Serializes concurrent claims on the same task
  with a transaction-scoped Postgres advisory lock (same approach as
  `Magus.Agents.RunOrchestrator`), then re-reads the row under the lock and
  aborts if the task is no longer claimable. Runs in the action's transaction,
  so a failed guard rolls back and releases the lock.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      task_id = cs.data.id

      Magus.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1), 0)", [to_string(task_id)])

      current =
        Magus.Plan.Task
        |> Ash.Query.filter(id == ^task_id)
        |> Ash.read_one!(authorize?: false)

      if claimable?(current) do
        cs
      else
        Ash.Changeset.add_error(
          cs,
          Magus.Plan.Errors.AlreadyClaimed.exception(task_id: task_id)
        )
      end
    end)
  end

  defp claimable?(%{
         status: :open,
         assigned_to_user_id: nil,
         assigned_to_agent: nil,
         assigned_to_custom_agent_id: nil
       }),
       do: true

  defp claimable?(_), do: false
end
