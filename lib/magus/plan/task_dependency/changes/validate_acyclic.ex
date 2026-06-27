defmodule Magus.Plan.TaskDependency.Changes.ValidateAcyclic do
  @moduledoc """
  Rejects invalid dependency edges on create:
    * self-dependency (task depends on itself)
    * cross-plan edges (the two tasks belong to different plan pages)
    * cycles (depends_on can already reach task via existing edges)
  Graphs are small (per-plan), so the reachability walk runs in-app.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      task_id = Ash.Changeset.get_attribute(cs, :task_id)
      depends_on_id = Ash.Changeset.get_attribute(cs, :depends_on_id)

      cond do
        task_id == depends_on_id ->
          Ash.Changeset.add_error(cs,
            field: :depends_on_id,
            message: "a task cannot depend on itself"
          )

        not same_plan?(task_id, depends_on_id) ->
          Ash.Changeset.add_error(cs,
            field: :depends_on_id,
            message: "dependencies must be within the same plan"
          )

        reachable?(depends_on_id, task_id) ->
          Ash.Changeset.add_error(cs,
            field: :depends_on_id,
            message: "this dependency would create a cycle"
          )

        true ->
          cs
      end
    end)
  end

  defp same_plan?(task_id, depends_on_id) do
    with {:ok, %{brain_page_id: p1}} when not is_nil(p1) <-
           Ash.get(Magus.Plan.Task, task_id, authorize?: false),
         {:ok, %{brain_page_id: p2}} <- Ash.get(Magus.Plan.Task, depends_on_id, authorize?: false) do
      p1 == p2
    else
      _ -> false
    end
  end

  # Can `from` reach `target` by following existing depends_on edges?
  defp reachable?(from, target), do: walk([from], MapSet.new(), target)

  defp walk([], _seen, _target), do: false

  defp walk([current | rest], seen, target) do
    cond do
      current == target ->
        true

      MapSet.member?(seen, current) ->
        walk(rest, seen, target)

      true ->
        next =
          Magus.Plan.TaskDependency
          |> Ash.Query.filter(task_id == ^current)
          |> Ash.read!(authorize?: false)
          |> Enum.map(& &1.depends_on_id)

        walk(next ++ rest, MapSet.put(seen, current), target)
    end
  end
end
