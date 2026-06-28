defmodule Magus.Plan.TaskEventTest do
  use Magus.ResourceCase, async: true

  alias Magus.Plan

  defp ctx do
    user = generate(user())
    brain = generate(brain(user_id: user.id))
    page = brain_page(brain_id: brain.id, user_id: user.id)
    %{user: user, page: page}
  end

  test "creating a plan task records a :created event" do
    %{user: user, page: page} = ctx()
    {:ok, task} = Plan.create_plan_task(page.id, %{title: "A"}, actor: user)

    {:ok, events} = Plan.task_events_for_plan(page.id, actor: user)
    assert Enum.any?(events, &(&1.task_id == task.id and &1.kind == :created))
  end

  test "claiming records a :claimed event with the actor label" do
    %{user: user, page: page} = ctx()
    {:ok, task} = Plan.create_plan_task(page.id, %{title: "A"}, actor: user)
    {:ok, _} = Plan.claim_task(task, %{assigned_to_agent: "claude-code"}, actor: user)

    {:ok, events} = Plan.task_events_for_plan(page.id, actor: user)
    claimed = Enum.find(events, &(&1.kind == :claimed))
    assert claimed.actor_label == "claude-code"
  end

  test "a stranger is forbidden from a plan's events (strict, not silently empty)" do
    %{user: user, page: page} = ctx()
    {:ok, _task} = Plan.create_plan_task(page.id, %{title: "A"}, actor: user)

    stranger = generate(user())
    assert {:error, _} = Plan.task_events_for_plan(page.id, actor: stranger)
  end
end
