defmodule Magus.Plan.TaskOverviewTest do
  use Magus.ResourceCase, async: true
  alias Magus.Plan

  defp ctx do
    user = generate(user())
    brain = generate(brain(user_id: user.id))
    p1 = brain_page(brain_id: brain.id, user_id: user.id)
    p2 = brain_page(brain_id: brain.id, user_id: user.id)
    %{user: user, brain: brain, p1: p1, p2: p2}
  end

  test "brain_task_overview rolls up tasks across all plans in the brain" do
    %{user: user, brain: brain, p1: p1, p2: p2} = ctx()
    {:ok, _} = Plan.create_plan_task(p1.id, %{title: "a"}, actor: user)
    {:ok, t2} = Plan.create_plan_task(p2.id, %{title: "b"}, actor: user)
    {:ok, _} = Plan.claim_task(t2, %{assigned_to_agent: "claude-code"}, actor: user)

    {:ok, overview} = Plan.brain_task_overview(brain.id, actor: user)
    assert length(overview.tasks) == 2
    assert Enum.any?(overview.activity, &(&1.kind in [:created, :claimed]))
  end

  test "a stranger cannot read a brain's overview" do
    %{brain: brain} = ctx()
    stranger = generate(user())
    assert {:error, _} = Plan.brain_task_overview(brain.id, actor: stranger)
  end
end
