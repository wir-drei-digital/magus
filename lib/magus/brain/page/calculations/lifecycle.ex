defmodule Magus.Brain.Page.Calculations.Lifecycle do
  @moduledoc """
  Computes a plan/phase page's delivery lifecycle: `:draft -> :active -> :done
  -> :delivered`.

  This is the core anti-stranding mechanism. `:done` is derived from the task
  rollup (recursive over child `:plan` phases); `:delivered` is an explicit gate
  set by `mark_delivered`. The `:stranded_plans` read surfaces plans that are
  `:done` but were never delivered.

    * `:delivered`: `delivered_at` is set (explicit gate; wins over the rollup).
    * `:done`: there is real work (>=1 non-cancelled direct task OR >=1 child
      phase) AND every non-cancelled direct task is `:done` AND every child phase
      is `:done` or `:delivered`. An empty plan (no tasks, no phases) is
      therefore NOT vacuously done.
    * `:active`: there is real work that is not all complete: any non-cancelled
      direct task exists (in any status), or any child phase has progressed past
      `:draft`.
    * `:draft`: nothing has started: no non-cancelled task and no child phase
      past `:draft`. A plan whose only tasks are cancelled stays `:draft`.

  Recursion terminates because a page with no `child_plan_pages` is a base case;
  `child_plan_pages: [:lifecycle]` loads this same calc one level down.
  """

  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context) do
    [:delivered_at, :kind, tasks: [:status], child_plan_pages: [:lifecycle]]
  end

  @impl true
  def calculate(pages, _opts, _context) do
    Enum.map(pages, fn page ->
      cond do
        not is_nil(page.delivered_at) -> :delivered
        done?(page) -> :done
        active?(page) -> :active
        true -> :draft
      end
    end)
  end

  defp done?(page) do
    tasks = active_tasks(page)
    phases = page.child_plan_pages || []

    (tasks != [] or phases != []) and
      Enum.all?(tasks, &(&1.status == :done)) and
      Enum.all?(phases, &(&1.lifecycle in [:done, :delivered]))
  end

  # Real work that is not yet all complete. `done?` is checked first by the
  # caller, so reaching here means the work (if any) is incomplete. Any
  # non-cancelled task counts (including :open); a child phase counts once it
  # has moved past :draft.
  defp active?(page) do
    active_tasks(page) != [] or
      Enum.any?(page.child_plan_pages || [], &(&1.lifecycle != :draft))
  end

  # Cancelled tasks are excluded from the rollup: they neither block `:done` nor
  # count as real work keeping a plan out of `:draft`.
  defp active_tasks(page) do
    Enum.reject(page.tasks || [], &(&1.status == :cancelled))
  end
end
