defmodule Magus.Plan.Task.Changes.EnforceTaskCap do
  @moduledoc """
  Before-action guard for `:create_plan`: rejects creation when the target plan
  already holds `:max_open_tasks_per_plan` non-terminal tasks (status not in
  done/cancelled/archived). Counts with `authorize?: false` (the actor was
  already authorized to create on this plan by the action policy).
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      brain_page_id = Ash.Changeset.get_argument(cs, :brain_page_id)
      cap = Application.get_env(:magus, :max_open_tasks_per_plan, 200)

      open_count =
        Magus.Plan.Task
        |> Ash.Query.filter(
          brain_page_id == ^brain_page_id and
            status not in [:done, :cancelled, :archived]
        )
        |> Ash.count!(authorize?: false)

      if open_count >= cap do
        Ash.Changeset.add_error(
          cs,
          Magus.Plan.Errors.PlanTaskCapReached.exception(
            brain_page_id: brain_page_id,
            cap: cap
          )
        )
      else
        cs
      end
    end)
  end
end
