defmodule Magus.Plan.TaskClaimTest do
  use Magus.ResourceCase, async: true

  alias Magus.Plan

  defp ctx do
    user = generate(user())
    brain = generate(brain(user_id: user.id))
    page = brain_page(brain_id: brain.id, user_id: user.id)
    {:ok, task} = Plan.create_plan_task(page.id, %{title: "Claimable"}, actor: user)
    %{user: user, page: page, task: task}
  end

  test "claim sets the assignee, marks in_progress, and stamps claimed_at" do
    %{user: user, task: task} = ctx()

    {:ok, claimed} = Plan.claim_task(task, %{assigned_to_agent: "claude-code"}, actor: user)

    assert claimed.assigned_to_agent == "claude-code"
    assert claimed.status == :in_progress
    refute is_nil(claimed.claimed_at)
  end

  test "claiming with neither an assignee user nor an agent fails" do
    %{user: user, task: task} = ctx()

    # A claim must record an owner; with neither field the validation rejects it
    # so we never set :in_progress/claimed_at without an assignee.
    assert {:error, _} = Plan.claim_task(task, %{}, actor: user)
  end

  test "claiming an already-claimed task fails" do
    %{user: user, task: task} = ctx()
    {:ok, _} = Plan.claim_task(task, %{assigned_to_agent: "agent-1"}, actor: user)

    # The generic :read action does not authorize plan tasks in Plan 1, so we
    # cannot reload via get_task. Instead, claim again with the same (now-stale)
    # in-memory struct. ClaimTask re-reads the live row under the advisory lock
    # by cs.data.id, so it must still detect the task is already claimed.
    assert {:error, _} = Plan.claim_task(task, %{assigned_to_agent: "agent-2"}, actor: user)
  end

  test "a second claim returns a typed AlreadyClaimed error" do
    %{user: user, task: task} = ctx()
    {:ok, _} = Plan.claim_task(task, %{assigned_to_agent: "agent-1"}, actor: user)

    assert {:error, error} = Plan.claim_task(task, %{assigned_to_agent: "agent-2"}, actor: user)
    assert Enum.any?(List.wrap(error.errors), &match?(%Magus.Plan.Errors.AlreadyClaimed{}, &1))
  end

  test "release returns a claimed task to the ready pool" do
    %{user: user, page: page, task: task} = ctx()
    {:ok, claimed} = Plan.claim_task(task, %{assigned_to_agent: "agent-1"}, actor: user)

    {:ok, released} = Plan.release_task(claimed, actor: user)

    assert is_nil(released.assigned_to_agent)
    assert is_nil(released.assigned_to_user_id)
    assert is_nil(released.claimed_at)
    assert released.status == :open

    {:ok, ready} = Plan.ready_tasks_for_plan(page.id, actor: user)
    assert task.id in Enum.map(ready, & &1.id)
  end
end
