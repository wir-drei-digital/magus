defmodule Magus.Plan.TaskReadyTest do
  use Magus.ResourceCase, async: true

  alias Magus.Plan

  defp ctx do
    user = generate(user())
    brain = generate(brain(user_id: user.id))
    page = brain_page(brain_id: brain.id, user_id: user.id)
    %{user: user, page: page}
  end

  test "an open, unassigned, dependency-free task is ready" do
    %{user: user, page: page} = ctx()
    {:ok, task} = Plan.create_plan_task(page.id, %{title: "A"}, actor: user)

    {:ok, [ready]} = Plan.ready_tasks_for_plan(page.id, actor: user)
    assert ready.id == task.id
  end

  test "an assigned task is not ready" do
    %{user: user, page: page} = ctx()

    {:ok, _} =
      Plan.create_plan_task(page.id, %{title: "A", assigned_to_agent: "claude-code"}, actor: user)

    {:ok, ready} = Plan.ready_tasks_for_plan(page.id, actor: user)
    assert ready == []
  end

  test "a task blocked by an incomplete dependency is not ready" do
    %{user: user, page: page} = ctx()
    {:ok, a} = Plan.create_plan_task(page.id, %{title: "A"}, actor: user)
    {:ok, b} = Plan.create_plan_task(page.id, %{title: "B"}, actor: user)
    {:ok, _} = Plan.add_task_dependency(b.id, a.id, actor: user)

    {:ok, ready} = Plan.ready_tasks_for_plan(page.id, actor: user)
    assert Enum.map(ready, & &1.id) == [a.id]
  end

  test "completing the dependency makes the dependent ready" do
    %{user: user, page: page} = ctx()
    {:ok, a} = Plan.create_plan_task(page.id, %{title: "A"}, actor: user)
    {:ok, b} = Plan.create_plan_task(page.id, %{title: "B"}, actor: user)
    {:ok, _} = Plan.add_task_dependency(b.id, a.id, actor: user)
    {:ok, _} = Plan.update_task(a, %{status: :done}, actor: user)

    {:ok, ready} = Plan.ready_tasks_for_plan(page.id, actor: user)
    assert b.id in Enum.map(ready, & &1.id)
  end

  test "a task assigned to a custom agent is not ready" do
    %{user: user, page: page} = ctx()
    # A real custom agent: assigning a non-existent UUID trips the AgentInboxEvent
    # FK in NotifyAgentAssignment, so we need a persisted agent to assign.
    agent = custom_agent(user)

    {:ok, _} =
      Plan.create_plan_task(page.id, %{title: "A"}, actor: user)
      |> then(fn {:ok, t} ->
        Plan.update_task(t, %{assigned_to_custom_agent_id: agent.id}, actor: user)
      end)

    {:ok, ready} = Plan.ready_tasks_for_plan(page.id, actor: user)
    assert ready == []
  end

  describe ":ready_for_brain" do
    test "returns ready tasks across every plan page in the brain, priority-ordered" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      page_a = brain_page(brain_id: brain.id, user_id: user.id, title: "A")
      page_b = brain_page(brain_id: brain.id, user_id: user.id, title: "B")

      {:ok, low} = Plan.create_plan_task(page_a.id, %{title: "low", priority: :low}, actor: user)

      {:ok, urgent} =
        Plan.create_plan_task(page_b.id, %{title: "urgent", priority: :urgent}, actor: user)

      # A claimed task is not ready and must not appear.
      {:ok, claimed} = Plan.create_plan_task(page_a.id, %{title: "taken"}, actor: user)
      {:ok, _} = Plan.claim_task(claimed, %{assigned_to_agent: "a@1"}, actor: user)

      {:ok, ready} = Plan.ready_tasks_for_brain(brain.id, actor: user)
      ids = Enum.map(ready, & &1.id)

      assert urgent.id in ids
      assert low.id in ids
      refute claimed.id in ids
      # urgent sorts before low
      assert Enum.find_index(ids, &(&1 == urgent.id)) < Enum.find_index(ids, &(&1 == low.id))
    end

    test "a stranger is forbidden (strict, not silently empty)" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      page = brain_page(brain_id: brain.id, user_id: user.id)
      {:ok, _} = Plan.create_plan_task(page.id, %{title: "a"}, actor: user)

      stranger = generate(user())
      assert {:error, _} = Plan.ready_tasks_for_brain(brain.id, actor: stranger)
    end
  end
end
