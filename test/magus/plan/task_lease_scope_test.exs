defmodule Magus.Plan.TaskLeaseScopeTest do
  @moduledoc """
  Regression coverage for the lease/reaper leak onto conversation tasks.

  `Magus.Plan.Task` backs both plan tasks (have a `brain_page_id`) and
  conversation tasks (have a `conversation_id`, `brain_page_id` is nil).
  The claim/lease coordination model applies to plan tasks only. A
  conversation task must never be leased and must never be reaped, even
  when a user drives it to `:in_progress` through the shared `:update`
  action.
  """
  use Magus.ResourceCase, async: true

  require Ash.Query

  alias Magus.Plan
  alias Magus.Plan.Task

  setup do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
    %{user: user, conversation: conversation}
  end

  describe "lease/reaper is plan-task-only" do
    test "a conversation task is never leased when set to in_progress", %{
      user: user,
      conversation: conversation
    } do
      {:ok, task} = Plan.create_task(conversation.id, %{title: "Chat task"}, actor: user)
      assert is_nil(task.brain_page_id)
      assert is_nil(task.lease_expires_at)

      {:ok, updated} = Plan.update_task(task, %{status: :in_progress}, actor: user)

      assert updated.status == :in_progress
      # Without Fix 1 (RenewLease scoping) this would be a future timestamp.
      assert is_nil(updated.lease_expires_at)
    end

    test "a conversation task with a forced stale lease is never in :stale_claims", %{
      user: user,
      conversation: conversation
    } do
      {:ok, task} = Plan.create_task(conversation.id, %{title: "Chat task"}, actor: user)
      {:ok, in_progress} = Plan.update_task(task, %{status: :in_progress}, actor: user)

      # Force a past lease so it would qualify as stale if the calc did not
      # exclude conversation tasks. force_change makes it stick even though
      # Fix 1 normally prevents conversation tasks from carrying a lease.
      {:ok, leaked} =
        in_progress
        |> Ash.Changeset.for_update(:update, %{}, actor: user)
        |> Ash.Changeset.force_change_attribute(
          :lease_expires_at,
          DateTime.add(DateTime.utc_now(), -60, :second)
        )
        |> Ash.update()

      refute is_nil(leaked.lease_expires_at)
      assert is_nil(leaked.brain_page_id)

      stale =
        Task
        |> Ash.Query.for_read(:stale_claims)
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.id)

      # Without Fix 2 (is_stale brain_page_id guard) this id would be present.
      refute leaked.id in stale
    end
  end
end
