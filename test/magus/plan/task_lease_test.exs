defmodule Magus.Plan.TaskLeaseTest do
  use Magus.ResourceCase, async: true

  alias Magus.Plan

  setup do
    user = generate(user())
    brain = generate(brain(user_id: user.id))
    page = brain_page(brain_id: brain.id, user_id: user.id)
    %{user: user, brain: brain, page: page}
  end

  describe "lease + lineage attributes" do
    test "a freshly created task has a nil lease_expires_at", %{user: user, page: page} do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Pull me"}, actor: user)

      assert is_nil(task.lease_expires_at)
    end
  end

  describe "created_by_label lineage" do
    test "create_plan persists the created_by_label", %{user: user, page: page} do
      {:ok, task} =
        Plan.create_plan_task(
          page.id,
          %{title: "X", created_by_label: "claude-code@sess_abc"},
          actor: user
        )

      assert task.created_by_label == "claude-code@sess_abc"
    end
  end

  describe ":claim sets a lease" do
    test "claiming an open task sets lease_expires_at ~ now + TTL", %{user: user, page: page} do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Claimable"}, actor: user)

      {:ok, claimed} =
        Plan.claim_task(task, %{assigned_to_agent: "claude-code@sess_1"}, actor: user)

      ttl = Application.fetch_env!(:magus, :task_lease_ttl_seconds)
      assert claimed.status == :in_progress
      refute is_nil(claimed.lease_expires_at)

      expected = DateTime.add(DateTime.utc_now(), ttl, :second)
      # within a 60s tolerance window
      assert abs(DateTime.diff(claimed.lease_expires_at, expected, :second)) <= 60
    end
  end

  describe "renew-on-activity + release" do
    test "updating an in_progress task bumps the lease", %{user: user, page: page} do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Active"}, actor: user)
      {:ok, claimed} = Plan.claim_task(task, %{assigned_to_agent: "a@1"}, actor: user)

      {:ok, backdated} =
        claimed
        |> Ash.Changeset.for_update(:update, %{}, actor: user)
        |> Ash.Changeset.force_change_attribute(
          :lease_expires_at,
          DateTime.add(DateTime.utc_now(), 30, :second)
        )
        |> Ash.update()

      before = backdated.lease_expires_at
      {:ok, updated} = Plan.update_task(backdated, %{title: "Active (edited)"}, actor: user)

      assert DateTime.compare(updated.lease_expires_at, before) == :gt
    end

    test "updating an open (unclaimed) task does not mint a lease", %{user: user, page: page} do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Idle"}, actor: user)

      {:ok, updated} = Plan.update_task(task, %{title: "Idle (edited)"}, actor: user)

      assert is_nil(updated.lease_expires_at)
    end

    test "release clears the lease", %{user: user, page: page} do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Toggle"}, actor: user)
      {:ok, claimed} = Plan.claim_task(task, %{assigned_to_agent: "a@1"}, actor: user)
      refute is_nil(claimed.lease_expires_at)

      {:ok, released} = Plan.release_task(claimed, actor: user)
      assert is_nil(released.lease_expires_at)
    end

    test "completing a claimed task clears the lease", %{user: user, page: page} do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Finish me"}, actor: user)
      {:ok, claimed} = Plan.claim_task(task, %{assigned_to_agent: "a@1"}, actor: user)
      refute is_nil(claimed.lease_expires_at)

      {:ok, completed} = Plan.complete_task(claimed, actor: user)
      assert completed.status == :done
      assert is_nil(completed.lease_expires_at)
    end

    test "updating a claimed task to a terminal status clears the lease", %{
      user: user,
      page: page
    } do
      {:ok, task} = Plan.create_plan_task(page.id, %{title: "Wrap up"}, actor: user)
      {:ok, claimed} = Plan.claim_task(task, %{assigned_to_agent: "a@1"}, actor: user)
      refute is_nil(claimed.lease_expires_at)

      {:ok, updated} = Plan.update_task(claimed, %{status: :done}, actor: user)

      assert updated.status == :done
      assert is_nil(updated.lease_expires_at)
    end
  end
end
