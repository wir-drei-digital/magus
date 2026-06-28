defmodule Magus.Brain.PageLifecycleTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Brain
  alias Magus.Plan

  setup do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "Test Brain"}, actor: user)
    %{user: user, brain: brain}
  end

  defp lifecycle(page, actor) do
    Ash.load!(page, [:lifecycle], actor: actor).lifecycle
  end

  describe "lifecycle computation" do
    test "a :plan page with no tasks and no child phases is :draft", %{user: user, brain: brain} do
      {:ok, plan} = Brain.create_page(brain.id, %{title: "Empty Plan", kind: :plan}, actor: user)

      assert lifecycle(plan, user) == :draft
    end

    test "a plain :page (no tasks) is also :draft", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{title: "Plain"}, actor: user)

      assert lifecycle(page, user) == :draft
    end

    test "a plan with one open task is :active", %{user: user, brain: brain} do
      {:ok, plan} = Brain.create_page(brain.id, %{title: "Active Plan", kind: :plan}, actor: user)
      {:ok, _task} = Plan.create_plan_task(plan.id, %{title: "Do thing"}, actor: user)

      assert lifecycle(plan, user) == :active
    end

    test "a plan with all non-cancelled tasks done is :done", %{user: user, brain: brain} do
      {:ok, plan} = Brain.create_page(brain.id, %{title: "Done Plan", kind: :plan}, actor: user)
      {:ok, t1} = Plan.create_plan_task(plan.id, %{title: "A"}, actor: user)
      {:ok, t2} = Plan.create_plan_task(plan.id, %{title: "B"}, actor: user)
      {:ok, cancelled} = Plan.create_plan_task(plan.id, %{title: "C"}, actor: user)

      {:ok, _} = Plan.update_task(t1, %{status: :done}, actor: user)
      {:ok, _} = Plan.update_task(t2, %{status: :done}, actor: user)
      # The cancelled task must NOT block :done.
      {:ok, _} = Plan.update_task(cancelled, %{status: :cancelled}, actor: user)

      assert lifecycle(plan, user) == :done
    end

    test "a plan with a single cancelled task (no real work) is NOT done", %{
      user: user,
      brain: brain
    } do
      # Edge: all tasks cancelled => no non-cancelled task and no child phase, so
      # the plan is not vacuously :done. It stays :draft (no active work either).
      {:ok, plan} =
        Brain.create_page(brain.id, %{title: "Cancelled Plan", kind: :plan}, actor: user)

      {:ok, t1} = Plan.create_plan_task(plan.id, %{title: "Only"}, actor: user)
      {:ok, _} = Plan.update_task(t1, %{status: :cancelled}, actor: user)

      assert lifecycle(plan, user) == :draft
    end

    test "a plan with a done task and an archived task is :done (archived does not block)", %{
      user: user,
      brain: brain
    } do
      # Archived is terminal everywhere else in the Plan domain, so an archived
      # task must not keep a plan :active forever. done task + archived task =>
      # :done.
      {:ok, plan} =
        Brain.create_page(brain.id, %{title: "Done w/ Archived", kind: :plan}, actor: user)

      {:ok, t1} = Plan.create_plan_task(plan.id, %{title: "Done one"}, actor: user)
      {:ok, t2} = Plan.create_plan_task(plan.id, %{title: "Archived one"}, actor: user)

      {:ok, _} = Plan.update_task(t1, %{status: :done}, actor: user)
      # The archived task must NOT block :done.
      {:ok, _} = Plan.update_task(t2, %{status: :archived}, actor: user)

      assert lifecycle(plan, user) == :done
    end

    test "a plan with a single archived task (no real work) is :draft", %{
      user: user,
      brain: brain
    } do
      # Like the cancelled edge: an archived-only plan has no active work, so it
      # is not vacuously :done and stays :draft.
      {:ok, plan} =
        Brain.create_page(brain.id, %{title: "Archived Plan", kind: :plan}, actor: user)

      {:ok, t1} = Plan.create_plan_task(plan.id, %{title: "Only"}, actor: user)
      {:ok, _} = Plan.update_task(t1, %{status: :archived}, actor: user)

      assert lifecycle(plan, user) == :draft
    end

    test "a plan with one in_progress task is :active", %{user: user, brain: brain} do
      {:ok, plan} = Brain.create_page(brain.id, %{title: "WIP Plan", kind: :plan}, actor: user)
      {:ok, t1} = Plan.create_plan_task(plan.id, %{title: "A"}, actor: user)
      {:ok, _t2} = Plan.create_plan_task(plan.id, %{title: "B"}, actor: user)
      {:ok, _} = Plan.update_task(t1, %{status: :in_progress}, actor: user)

      assert lifecycle(plan, user) == :active
    end
  end

  describe "delivery gate" do
    test "mark_delivered flips a :done plan to :delivered, undeliver returns it to :done", %{
      user: user,
      brain: brain
    } do
      {:ok, plan} = Brain.create_page(brain.id, %{title: "Ship Plan", kind: :plan}, actor: user)
      {:ok, t1} = Plan.create_plan_task(plan.id, %{title: "A"}, actor: user)
      {:ok, _} = Plan.update_task(t1, %{status: :done}, actor: user)

      assert lifecycle(plan, user) == :done

      {:ok, delivered} = Brain.mark_page_delivered(plan, %{delivery_ref: "v1.0"}, actor: user)
      assert delivered.delivery_ref == "v1.0"
      assert delivered.delivered_at != nil
      assert lifecycle(delivered, user) == :delivered

      {:ok, undelivered} = Brain.undeliver_page(delivered, actor: user)
      assert undelivered.delivered_at == nil
      assert undelivered.delivery_ref == nil
      assert lifecycle(undelivered, user) == :done
    end

    test "delivered_at takes priority even if tasks are still open", %{user: user, brain: brain} do
      # delivered is an explicit gate: it wins over the task rollup.
      {:ok, plan} = Brain.create_page(brain.id, %{title: "Forced Ship", kind: :plan}, actor: user)
      {:ok, _t1} = Plan.create_plan_task(plan.id, %{title: "Still open"}, actor: user)

      {:ok, delivered} = Brain.mark_page_delivered(plan, %{}, actor: user)
      assert lifecycle(delivered, user) == :delivered
    end
  end

  describe "recursive phase rollup" do
    test "a plan whose direct tasks are done but a child phase is still active is :active", %{
      user: user,
      brain: brain
    } do
      {:ok, parent} =
        Brain.create_page(brain.id, %{title: "Parent Plan", kind: :plan}, actor: user)

      # Parent's own direct task is done.
      {:ok, pt} = Plan.create_plan_task(parent.id, %{title: "Parent task"}, actor: user)
      {:ok, _} = Plan.update_task(pt, %{status: :done}, actor: user)

      # A child phase (nested :plan page) with an open task => the child is :active.
      {:ok, child} =
        Brain.create_page(
          brain.id,
          %{title: "Child Phase", kind: :plan, parent_page_id: parent.id},
          actor: user
        )

      {:ok, _ct} = Plan.create_plan_task(child.id, %{title: "Child task"}, actor: user)

      assert lifecycle(child, user) == :active
      # Parent is NOT done because the child phase is not done/delivered.
      assert lifecycle(parent, user) == :active
    end

    test "a plan with done direct tasks and all child phases done is :done", %{
      user: user,
      brain: brain
    } do
      {:ok, parent} =
        Brain.create_page(brain.id, %{title: "Parent Done", kind: :plan}, actor: user)

      {:ok, pt} = Plan.create_plan_task(parent.id, %{title: "Parent task"}, actor: user)
      {:ok, _} = Plan.update_task(pt, %{status: :done}, actor: user)

      {:ok, child} =
        Brain.create_page(
          brain.id,
          %{title: "Child Done", kind: :plan, parent_page_id: parent.id},
          actor: user
        )

      {:ok, ct} = Plan.create_plan_task(child.id, %{title: "Child task"}, actor: user)
      {:ok, _} = Plan.update_task(ct, %{status: :done}, actor: user)

      assert lifecycle(child, user) == :done
      assert lifecycle(parent, user) == :done
    end

    test "a plan with zero direct tasks but a done child phase is :done", %{
      user: user,
      brain: brain
    } do
      # done? requires >=1 non-cancelled task OR >=1 child phase. Here the parent
      # has no direct tasks but one done child phase => :done.
      {:ok, parent} =
        Brain.create_page(brain.id, %{title: "Phase Container", kind: :plan}, actor: user)

      {:ok, child} =
        Brain.create_page(
          brain.id,
          %{title: "Only Phase", kind: :plan, parent_page_id: parent.id},
          actor: user
        )

      {:ok, ct} = Plan.create_plan_task(child.id, %{title: "Child task"}, actor: user)
      {:ok, _} = Plan.update_task(ct, %{status: :done}, actor: user)

      assert lifecycle(parent, user) == :done
    end

    test "a non-:plan child does not count toward the phase rollup", %{user: user, brain: brain} do
      # child_plan_pages filters kind == :plan, so a plain child :page must not
      # affect the parent plan's lifecycle. Parent with a done direct task and a
      # plain (non-plan) child page is still :done.
      {:ok, parent} =
        Brain.create_page(brain.id, %{title: "Plan w/ doc child", kind: :plan}, actor: user)

      {:ok, pt} = Plan.create_plan_task(parent.id, %{title: "Parent task"}, actor: user)
      {:ok, _} = Plan.update_task(pt, %{status: :done}, actor: user)

      {:ok, _doc} =
        Brain.create_page(
          brain.id,
          %{title: "Notes", kind: :page, parent_page_id: parent.id},
          actor: user
        )

      assert lifecycle(parent, user) == :done
    end
  end

  describe ":stranded_plans" do
    test "returns done-but-not-delivered plans, excluding active and delivered", %{
      user: user,
      brain: brain
    } do
      # Stranded: done, not delivered.
      {:ok, stranded} =
        Brain.create_page(brain.id, %{title: "Stranded", kind: :plan}, actor: user)

      {:ok, s_task} = Plan.create_plan_task(stranded.id, %{title: "A"}, actor: user)
      {:ok, _} = Plan.update_task(s_task, %{status: :done}, actor: user)

      # Delivered: done AND delivered => excluded.
      {:ok, shipped} = Brain.create_page(brain.id, %{title: "Shipped", kind: :plan}, actor: user)
      {:ok, sh_task} = Plan.create_plan_task(shipped.id, %{title: "A"}, actor: user)
      {:ok, _} = Plan.update_task(sh_task, %{status: :done}, actor: user)
      {:ok, _} = Brain.mark_page_delivered(shipped, %{delivery_ref: "done"}, actor: user)

      # Active: not done => excluded.
      {:ok, active} = Brain.create_page(brain.id, %{title: "Active", kind: :plan}, actor: user)
      {:ok, _a_task} = Plan.create_plan_task(active.id, %{title: "A"}, actor: user)

      # A :spec page that is done-ish must not appear (filter is kind == :plan).
      {:ok, _spec} = Brain.create_page(brain.id, %{title: "Spec", kind: :spec}, actor: user)

      {:ok, stranded_plans} = Brain.stranded_plans(brain.id, actor: user)
      ids = Enum.map(stranded_plans, & &1.id)

      assert stranded.id in ids
      refute shipped.id in ids
      refute active.id in ids
    end

    test "excludes trashed plans", %{user: user, brain: brain} do
      {:ok, plan} = Brain.create_page(brain.id, %{title: "Trashed", kind: :plan}, actor: user)
      {:ok, task} = Plan.create_plan_task(plan.id, %{title: "A"}, actor: user)
      {:ok, _} = Plan.update_task(task, %{status: :done}, actor: user)

      {:ok, _} = Brain.soft_delete_page(plan, actor: user)

      {:ok, stranded_plans} = Brain.stranded_plans(brain.id, actor: user)
      refute plan.id in Enum.map(stranded_plans, & &1.id)
    end

    test "a stranger cannot read another brain's stranded plans", %{user: user, brain: brain} do
      {:ok, plan} = Brain.create_page(brain.id, %{title: "Secret", kind: :plan}, actor: user)
      {:ok, task} = Plan.create_plan_task(plan.id, %{title: "A"}, actor: user)
      {:ok, _} = Plan.update_task(task, %{status: :done}, actor: user)

      stranger = generate(user())

      {:ok, stranded_plans} = Brain.stranded_plans(brain.id, actor: stranger)
      assert stranded_plans == []
    end
  end
end
