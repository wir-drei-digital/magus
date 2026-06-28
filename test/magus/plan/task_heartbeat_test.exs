defmodule Magus.Plan.TaskHeartbeatTest do
  use Magus.ResourceCase, async: true

  alias Magus.Plan
  alias Magus.Plan.Errors.NotClaimant

  setup do
    user = generate(user())
    brain = generate(brain(user_id: user.id))
    page = brain_page(brain_id: brain.id, user_id: user.id)
    {:ok, task} = Plan.create_plan_task(page.id, %{title: "Long job"}, actor: user)
    {:ok, claimed} = Plan.claim_task(task, %{assigned_to_agent: "claude-code@A"}, actor: user)
    %{user: user, page: page, task: claimed}
  end

  describe ":heartbeat" do
    test "the current claimant renews the lease", %{user: user, task: task} do
      # Backdate the lease so a renew is observable.
      {:ok, task} =
        task
        |> Ash.Changeset.for_update(:update, %{}, actor: user)
        |> Ash.Changeset.force_change_attribute(
          :lease_expires_at,
          DateTime.add(DateTime.utc_now(), 30, :second)
        )
        |> Ash.update()

      before = task.lease_expires_at
      {:ok, beat} = Plan.heartbeat_task(task, %{as: "claude-code@A"}, actor: user)

      assert DateTime.compare(beat.lease_expires_at, before) == :gt
    end

    test "a different label is rejected with NotClaimant", %{user: user, task: task} do
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Plan.heartbeat_task(task, %{as: "claude-code@B"}, actor: user)

      assert Enum.any?(errors, &match?(%NotClaimant{}, &1))
    end

    test "a task that is not in_progress is rejected with NotClaimant", %{user: user, task: task} do
      {:ok, released} = Plan.release_task(task, actor: user)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Plan.heartbeat_task(released, %{as: "claude-code@A"}, actor: user)

      assert Enum.any?(errors, &match?(%NotClaimant{}, &1))
    end
  end
end
