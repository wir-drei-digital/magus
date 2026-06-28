defmodule Magus.Plan.TaskReaperTest do
  use Magus.ResourceCase, async: true

  require Ash.Query

  alias Magus.Plan
  alias Magus.Plan.Task

  setup do
    user = generate(user())
    brain = generate(brain(user_id: user.id))
    page = brain_page(brain_id: brain.id, user_id: user.id)
    %{user: user, brain: brain, page: page}
  end

  defp claim_and_backdate(page, user, label, lease_offset_seconds) do
    {:ok, task} = Plan.create_plan_task(page.id, %{title: "Job #{label}"}, actor: user)
    {:ok, claimed} = Plan.claim_task(task, %{assigned_to_agent: label}, actor: user)

    claimed
    |> Ash.Changeset.for_update(:update, %{}, actor: user)
    |> Ash.Changeset.force_change_attribute(
      :lease_expires_at,
      DateTime.add(DateTime.utc_now(), lease_offset_seconds, :second)
    )
    |> Ash.update!()
  end

  describe "is_stale + :stale_claims" do
    test "an in_progress task with an expired lease is stale; a future lease is not", %{
      user: user,
      page: page
    } do
      expired = claim_and_backdate(page, user, "a@expired", -60)
      fresh = claim_and_backdate(page, user, "a@fresh", 300)

      stale =
        Task
        |> Ash.Query.for_read(:stale_claims)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)

      assert expired.id in stale
      refute fresh.id in stale
    end

    test "an open task with a (stale) lease is not reaped", %{user: user, page: page} do
      task = claim_and_backdate(page, user, "a@released", -60)
      {:ok, released} = Plan.release_task(task, actor: user)

      stale =
        Task
        |> Ash.Query.for_read(:stale_claims)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)

      refute released.id in stale
    end
  end

  describe ":reap_expired_claims" do
    test "reaps a stale task back to open and records a :lease_expired event", %{
      user: user,
      page: page,
      brain: brain
    } do
      task = claim_and_backdate(page, user, "a@dead", -60)

      # Stamp an assignment-lineage attribute so we can assert the reaper clears
      # it too (a reaped task must carry no stale assignment lineage).
      {:ok, task} =
        Plan.update_task(task, %{assigned_by_custom_agent_id: Ash.UUID.generate()}, actor: user)

      refute is_nil(task.assigned_by_custom_agent_id)

      {:ok, reaped} =
        task
        |> Ash.Changeset.for_update(:reap_expired_claims, %{})
        |> Ash.update(authorize?: false)

      assert reaped.status == :open
      assert is_nil(reaped.assigned_to_agent)
      assert is_nil(reaped.assigned_to_user_id)
      assert is_nil(reaped.assigned_by_custom_agent_id)
      assert is_nil(reaped.claimed_at)
      assert is_nil(reaped.lease_expires_at)

      {:ok, %{activity: events}} = Plan.brain_task_overview(brain.id, actor: user)
      reap_event = Enum.find(events, &(&1.kind == :lease_expired))
      assert reap_event
      assert reap_event.actor_label == "system:lease-reaper"
    end
  end
end
