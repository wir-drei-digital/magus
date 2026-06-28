defmodule Magus.Plan.TaskCapTest do
  # async: false on purpose: these tests mutate the GLOBAL
  # :max_open_tasks_per_plan config to shrink the cap, which would race any
  # concurrent async test that creates plan tasks (a known flake source here).
  use Magus.ResourceCase, async: false

  alias Magus.Plan

  setup do
    user = generate(user())
    brain = generate(brain(user_id: user.id))
    page = brain_page(brain_id: brain.id, user_id: user.id)
    %{user: user, brain: brain, page: page}
  end

  describe "max_open_tasks_per_plan cap" do
    test "create_plan past the cap returns PlanTaskCapReached", %{user: user, page: page} do
      original = Application.get_env(:magus, :max_open_tasks_per_plan)
      Application.put_env(:magus, :max_open_tasks_per_plan, 2)
      on_exit(fn -> Application.put_env(:magus, :max_open_tasks_per_plan, original) end)

      {:ok, _} = Plan.create_plan_task(page.id, %{title: "t1"}, actor: user)
      {:ok, _} = Plan.create_plan_task(page.id, %{title: "t2"}, actor: user)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Plan.create_plan_task(page.id, %{title: "t3"}, actor: user)

      assert Enum.any?(errors, &match?(%Magus.Plan.Errors.PlanTaskCapReached{}, &1))
    end

    test "done/cancelled tasks do not count toward the cap", %{user: user, page: page} do
      original = Application.get_env(:magus, :max_open_tasks_per_plan)
      Application.put_env(:magus, :max_open_tasks_per_plan, 2)
      on_exit(fn -> Application.put_env(:magus, :max_open_tasks_per_plan, original) end)

      {:ok, t1} = Plan.create_plan_task(page.id, %{title: "t1"}, actor: user)
      {:ok, _} = Plan.update_task(t1, %{status: :done}, actor: user)
      {:ok, _} = Plan.create_plan_task(page.id, %{title: "t2"}, actor: user)

      # t1 is done, so only t2 (open) counts toward the cap of 2; t3 is allowed.
      assert {:ok, _} = Plan.create_plan_task(page.id, %{title: "t3"}, actor: user)
    end
  end
end
