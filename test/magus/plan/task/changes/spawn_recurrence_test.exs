defmodule Magus.Plan.Task.Changes.SpawnRecurrenceTest do
  use Magus.ResourceCase, async: true

  alias Magus.Plan

  import Magus.Generators

  setup do
    user = generate(user())
    conversation = generate(conversation(actor: user))
    %{user: user, conversation: conversation}
  end

  describe "spawn_recurrence/0" do
    test "creates next task when recurring daily task completed", %{
      user: user,
      conversation: conversation
    } do
      due = DateTime.add(DateTime.utc_now(), 3600, :second)

      task =
        Plan.create_task!(
          conversation.id,
          %{
            title: "Daily practice",
            due_at: due,
            recurrence: %{frequency: :daily, interval: 1}
          },
          actor: user
        )

      Plan.update_task!(task, %{status: :done}, actor: user)

      {:ok, tasks} = Plan.tasks_for_conversation(conversation.id, actor: user)
      open_tasks = Enum.filter(tasks, &(&1.status == :open))

      assert length(open_tasks) == 1
      new_task = hd(open_tasks)
      assert new_task.title == "Daily practice"
      assert new_task.recurrence == %{"frequency" => "daily", "interval" => 1}
      assert DateTime.diff(new_task.due_at, due) >= 86400
    end

    test "creates next task when recurring weekly task completed", %{
      user: user,
      conversation: conversation
    } do
      due = DateTime.utc_now()

      task =
        Plan.create_task!(
          conversation.id,
          %{
            title: "Weekly review",
            due_at: due,
            recurrence: %{frequency: :weekly, interval: 1}
          },
          actor: user
        )

      Plan.update_task!(task, %{status: :done}, actor: user)

      {:ok, tasks} = Plan.tasks_for_conversation(conversation.id, actor: user)
      open_tasks = Enum.filter(tasks, &(&1.status == :open))

      assert length(open_tasks) == 1
      new_task = hd(open_tasks)
      assert DateTime.diff(new_task.due_at, due) >= 7 * 86400
    end

    test "does not spawn when non-recurring task completed", %{
      user: user,
      conversation: conversation
    } do
      task = Plan.create_task!(conversation.id, %{title: "One-time task"}, actor: user)
      Plan.update_task!(task, %{status: :done}, actor: user)

      {:ok, tasks} = Plan.tasks_for_conversation(conversation.id, actor: user)
      open_tasks = Enum.filter(tasks, &(&1.status == :open))
      assert Enum.empty?(open_tasks)
    end

    test "does not spawn when status changes to something other than done", %{
      user: user,
      conversation: conversation
    } do
      task =
        Plan.create_task!(
          conversation.id,
          %{
            title: "Recurring but not done",
            due_at: DateTime.utc_now(),
            recurrence: %{frequency: :daily, interval: 1}
          },
          actor: user
        )

      Plan.update_task!(task, %{status: :in_progress}, actor: user)

      {:ok, tasks} = Plan.tasks_for_conversation(conversation.id, actor: user)

      open_or_in_progress =
        Enum.filter(tasks, &(&1.status == :open || &1.status == :in_progress))

      assert length(open_or_in_progress) == 1
    end

    test "copies assignment fields to spawned task", %{
      user: user,
      conversation: conversation
    } do
      task =
        Plan.create_task!(
          conversation.id,
          %{
            title: "Assigned recurring",
            due_at: DateTime.utc_now(),
            recurrence: %{frequency: :daily, interval: 1},
            assigned_to_user_id: user.id
          },
          actor: user
        )

      Plan.update_task!(task, %{status: :done}, actor: user)

      {:ok, tasks} = Plan.tasks_for_conversation(conversation.id, actor: user)
      new_task = Enum.find(tasks, &(&1.status == :open))
      assert new_task.assigned_to_user_id == user.id
    end
  end
end
