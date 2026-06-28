defmodule Magus.Plan.TaskReaperTriggerTest do
  @moduledoc """
  End-to-end test of the :reap_expired_claims AshOban trigger.

  AshOban runs the scheduler read (and per-record worker read + action) with
  the AshObanInteraction context: `authorize?: true` and `actor: nil` (no
  actor_persister is configured). This exercises both the trigger wiring and
  the AshObanInteraction policy bypass, which must authorize the no-actor
  scheduler read so the stale task is selected and reaped.

  Runs `async: false` so the Ecto sandbox is in shared mode: the in-process
  Oban worker drained by schedule_and_run_triggers/2 shares the test's DB
  connection and can therefore see the stale task.
  """
  use Magus.ResourceCase, async: false

  require Ash.Query

  alias Magus.Plan
  alias Magus.Plan.Task

  setup do
    user = generate(user())
    brain = generate(brain(user_id: user.id))
    page = brain_page(brain_id: brain.id, user_id: user.id)
    %{user: user, brain: brain, page: page}
  end

  # Mirrors task_reaper_test.exs: create a plan task, claim it for an agent,
  # then force the lease into the past so the `is_stale` calculation is true.
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

  describe ":reap_expired_claims AshOban trigger" do
    test "the no-actor scheduler read selects the stale task only via the bypass", %{
      user: user,
      page: page
    } do
      stale = claim_and_backdate(page, user, "a@dead", -60)
      fresh = claim_and_backdate(page, user, "a@fresh", 300)

      # The scheduler reads :stale_claims with authorize?: true, a nil actor,
      # and the ash_oban? private-context flag (set internally by AshOban,
      # see deps/ash_oban/lib/ash_oban.ex). The AshObanInteraction bypass keys
      # on exactly that flag, so the no-actor read is authorized and selects
      # the stale row. Mirrors AgentRun: this resource has no per-action
      # always-bypass, so authorization flows solely through this context.
      via_bypass =
        Task
        |> Ash.Query.for_read(:stale_claims, %{}, authorize?: true, actor: nil)
        |> Ash.Query.set_context(%{private: %{ash_oban?: true}})
        |> Ash.read!()
        |> Enum.map(& &1.id)

      assert stale.id in via_bypass
      refute fresh.id in via_bypass

      # Control: without the ash_oban? flag the same no-actor read is gated by
      # the user-facing read policy and returns nothing, proving the row is
      # visible only through the bypass (not leaking to anonymous readers).
      without_bypass =
        Task
        |> Ash.Query.for_read(:stale_claims, %{}, authorize?: true, actor: nil)
        |> Ash.read!()
        |> Enum.map(& &1.id)

      refute stale.id in without_bypass
    end

    test "the trigger's where-filter selects the stale task", %{user: user, page: page} do
      import AshOban.Test, only: [assert_would_schedule: 2]

      stale = claim_and_backdate(page, user, "a@dead", -60)

      assert_would_schedule(stale, :reap_expired_claims)
    end

    test "running the trigger reaps a stale task back to open", %{user: user, page: page} do
      stale = claim_and_backdate(page, user, "a@dead", -60)

      # Schedules + drains the :plan_task_cleanup queue in-process (drain_queues?:
      # true). The worker runs the :reap_expired_claims action on the stale task.
      assert %{failure: 0} =
               AshOban.Test.schedule_and_run_triggers({Task, :reap_expired_claims})

      {:ok, reaped} = Plan.get_task(stale.id, actor: user)
      assert reaped.status == :open
      assert is_nil(reaped.assigned_to_agent)
      assert is_nil(reaped.lease_expires_at)
    end
  end
end
