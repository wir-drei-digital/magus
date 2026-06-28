defmodule Magus.Plan.TaskDependencyTest do
  use Magus.ResourceCase, async: true

  alias Magus.Plan

  defp ctx do
    user = generate(user())
    brain = generate(brain(user_id: user.id))
    page = brain_page(brain_id: brain.id, user_id: user.id)
    {:ok, a} = Plan.create_plan_task(page.id, %{title: "A"}, actor: user)
    {:ok, b} = Plan.create_plan_task(page.id, %{title: "B"}, actor: user)
    %{user: user, brain: brain, page: page, a: a, b: b}
  end

  test "adds a dependency (B depends on A)" do
    %{user: user, a: a, b: b} = ctx()
    {:ok, dep} = Plan.add_task_dependency(b.id, a.id, actor: user)
    assert dep.task_id == b.id
    assert dep.depends_on_id == a.id
  end

  test "rejects a self-dependency" do
    %{user: user, a: a} = ctx()
    {:error, _} = Plan.add_task_dependency(a.id, a.id, actor: user)
  end

  test "rejects a cycle (A->B then B->A)" do
    %{user: user, a: a, b: b} = ctx()
    {:ok, _} = Plan.add_task_dependency(a.id, b.id, actor: user)
    {:error, _} = Plan.add_task_dependency(b.id, a.id, actor: user)
  end

  test "rejects a cross-plan dependency" do
    %{user: user, brain: brain, a: a} = ctx()
    other_page = brain_page(brain_id: brain.id, user_id: user.id)
    {:ok, other} = Plan.create_plan_task(other_page.id, %{title: "Other"}, actor: user)
    {:error, _} = Plan.add_task_dependency(a.id, other.id, actor: user)
  end

  test "removing a dependency works" do
    %{user: user, a: a, b: b} = ctx()
    {:ok, dep} = Plan.add_task_dependency(b.id, a.id, actor: user)
    :ok = Plan.remove_task_dependency(dep, actor: user)
    assert {:ok, []} = Plan.dependencies_of(b.id, actor: user)
  end
end
