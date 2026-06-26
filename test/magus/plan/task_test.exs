defmodule Magus.Plan.TaskTest do
  use Magus.ResourceCase, async: true

  alias Magus.Plan

  @ai_agent %Magus.Agents.Support.AiAgent{}

  defp create_context do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
    %{user: user, conversation: conversation}
  end

  # ---------------------------------------------------------------------------
  # Creating top-level tasks
  # ---------------------------------------------------------------------------

  describe "create top-level task" do
    test "creates a task for a conversation" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} =
        Plan.create_task(conversation.id, %{title: "Buy milk"}, actor: user)

      assert task.title == "Buy milk"
      assert task.conversation_id == conversation.id
      assert task.status == :open
      assert is_nil(task.parent_id)
    end

    test "sets description when provided" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} =
        Plan.create_task(conversation.id, %{title: "Task", description: "Some details"},
          actor: user
        )

      assert task.description == "Some details"
    end

    test "metadata defaults to empty map" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} = Plan.create_task(conversation.id, %{title: "Task"}, actor: user)

      assert task.metadata == %{}
    end

    test "title is required" do
      %{user: user, conversation: conversation} = create_context()

      {:error, _error} = Plan.create_task(conversation.id, %{}, actor: user)
    end
  end

  # ---------------------------------------------------------------------------
  # Auto-incrementing position
  # ---------------------------------------------------------------------------

  describe "auto_position" do
    test "first task in a conversation gets position 1" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} = Plan.create_task(conversation.id, %{title: "First"}, actor: user)

      assert task.position == 1
    end

    test "subsequent tasks get incrementing positions" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, t1} = Plan.create_task(conversation.id, %{title: "First"}, actor: user)
      {:ok, t2} = Plan.create_task(conversation.id, %{title: "Second"}, actor: user)
      {:ok, t3} = Plan.create_task(conversation.id, %{title: "Third"}, actor: user)

      assert t1.position == 1
      assert t2.position == 2
      assert t3.position == 3
    end

    test "position is scoped per conversation" do
      %{user: user, conversation: conv1} = create_context()
      {:ok, conv2} = Chat.create_conversation(%{}, actor: user)

      {:ok, t1} = Plan.create_task(conv1.id, %{title: "Conv1 First"}, actor: user)
      {:ok, t2} = Plan.create_task(conv2.id, %{title: "Conv2 First"}, actor: user)

      assert t1.position == 1
      assert t2.position == 1
    end

    test "explicit position is respected when provided" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} = Plan.create_task(conversation.id, %{title: "Task", position: 10}, actor: user)

      assert task.position == 10
    end

    test "subtask positions are scoped to parent" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, parent} = Plan.create_task(conversation.id, %{title: "Parent"}, actor: user)

      {:ok, sub1} =
        Plan.create_task(conversation.id, %{title: "Sub 1", parent_id: parent.id}, actor: user)

      {:ok, sub2} =
        Plan.create_task(conversation.id, %{title: "Sub 2", parent_id: parent.id}, actor: user)

      assert sub1.position == 1
      assert sub2.position == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Creating subtasks
  # ---------------------------------------------------------------------------

  describe "subtasks" do
    test "creates a subtask under a parent" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, parent} = Plan.create_task(conversation.id, %{title: "Parent"}, actor: user)

      {:ok, subtask} =
        Plan.create_task(conversation.id, %{title: "Subtask", parent_id: parent.id}, actor: user)

      assert subtask.parent_id == parent.id
      assert subtask.conversation_id == conversation.id
    end

    test "multiple subtasks can share the same parent" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, parent} = Plan.create_task(conversation.id, %{title: "Parent"}, actor: user)

      {:ok, sub1} =
        Plan.create_task(conversation.id, %{title: "Sub 1", parent_id: parent.id}, actor: user)

      {:ok, sub2} =
        Plan.create_task(conversation.id, %{title: "Sub 2", parent_id: parent.id}, actor: user)

      assert sub1.parent_id == parent.id
      assert sub2.parent_id == parent.id
      assert sub1.id != sub2.id
    end
  end

  # ---------------------------------------------------------------------------
  # Nesting validation (depth > 1 rejected)
  # ---------------------------------------------------------------------------

  describe "validate_nesting" do
    test "rejects creating a task whose parent is already a subtask" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, grandparent} = Plan.create_task(conversation.id, %{title: "Grandparent"}, actor: user)

      {:ok, parent} =
        Plan.create_task(conversation.id, %{title: "Parent", parent_id: grandparent.id},
          actor: user
        )

      {:error, error} =
        Plan.create_task(conversation.id, %{title: "Child", parent_id: parent.id}, actor: user)

      assert_field_error(error, :parent_id, "cannot nest tasks more than one level deep")
    end

    test "allows a subtask (depth 1) without error" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, parent} = Plan.create_task(conversation.id, %{title: "Parent"}, actor: user)

      {:ok, subtask} =
        Plan.create_task(conversation.id, %{title: "Child", parent_id: parent.id}, actor: user)

      assert subtask.parent_id == parent.id
    end

    test "rejects updating parent_id to create deep nesting" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, grandparent} = Plan.create_task(conversation.id, %{title: "Grandparent"}, actor: user)

      {:ok, parent} =
        Plan.create_task(conversation.id, %{title: "Parent", parent_id: grandparent.id},
          actor: user
        )

      {:ok, orphan} = Plan.create_task(conversation.id, %{title: "Orphan"}, actor: user)

      {:error, error} = Plan.update_task(orphan, %{parent_id: parent.id}, actor: user)

      assert_field_error(error, :parent_id, "cannot nest tasks more than one level deep")
    end
  end

  # ---------------------------------------------------------------------------
  # Updating status/title
  # ---------------------------------------------------------------------------

  describe "update_task" do
    test "updates title" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} = Plan.create_task(conversation.id, %{title: "Old Title"}, actor: user)
      {:ok, updated} = Plan.update_task(task, %{title: "New Title"}, actor: user)

      assert updated.title == "New Title"
    end

    test "updates status" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} = Plan.create_task(conversation.id, %{title: "Task"}, actor: user)
      {:ok, updated} = Plan.update_task(task, %{status: :in_progress}, actor: user)

      assert updated.status == :in_progress
    end

    test "rejects invalid status" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} = Plan.create_task(conversation.id, %{title: "Task"}, actor: user)
      {:error, _error} = Plan.update_task(task, %{status: :invalid_status}, actor: user)
    end
  end

  # ---------------------------------------------------------------------------
  # completed_by auto-set on done
  # ---------------------------------------------------------------------------

  describe "set_completed_by" do
    test "sets completed_by to 'user' when a User marks task done" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} = Plan.create_task(conversation.id, %{title: "Task"}, actor: user)
      {:ok, updated} = Plan.update_task(task, %{status: :done}, actor: user)

      assert updated.completed_by == "user"
    end

    test "sets completed_by to 'agent' when an AI agent marks task done" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} = Plan.create_task(conversation.id, %{title: "Task"}, actor: user)
      {:ok, updated} = Plan.update_task(task, %{status: :done}, actor: @ai_agent)

      assert updated.completed_by == "agent"
    end

    test "does not set completed_by when status changes to something other than done" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} = Plan.create_task(conversation.id, %{title: "Task"}, actor: user)
      {:ok, updated} = Plan.update_task(task, %{status: :in_progress}, actor: user)

      assert is_nil(updated.completed_by)
    end
  end

  # ---------------------------------------------------------------------------
  # completed_by cleared on reopen
  # ---------------------------------------------------------------------------

  describe "completed_by cleared on reopen" do
    test "clears completed_by when task is reopened from done" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} = Plan.create_task(conversation.id, %{title: "Task"}, actor: user)
      {:ok, done} = Plan.update_task(task, %{status: :done}, actor: user)
      assert done.completed_by == "user"

      {:ok, reopened} = Plan.update_task(done, %{status: :open}, actor: user)
      assert is_nil(reopened.completed_by)
    end

    test "clears completed_by when task moves from done to in_progress" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} = Plan.create_task(conversation.id, %{title: "Task"}, actor: user)
      {:ok, done} = Plan.update_task(task, %{status: :done}, actor: @ai_agent)
      assert done.completed_by == "agent"

      {:ok, in_progress} = Plan.update_task(done, %{status: :in_progress}, actor: user)
      assert is_nil(in_progress.completed_by)
    end

    test "does not change completed_by when other fields change on done task" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} = Plan.create_task(conversation.id, %{title: "Task"}, actor: user)
      {:ok, done} = Plan.update_task(task, %{status: :done}, actor: user)
      assert done.completed_by == "user"

      {:ok, retitled} = Plan.update_task(done, %{title: "New Title"}, actor: user)
      assert retitled.completed_by == "user"
    end
  end

  # ---------------------------------------------------------------------------
  # Listing tasks for conversation (ordered, scoped)
  # ---------------------------------------------------------------------------

  describe "tasks_for_conversation" do
    test "returns tasks ordered by position ascending" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, _t1} = Plan.create_task(conversation.id, %{title: "First"}, actor: user)
      {:ok, _t2} = Plan.create_task(conversation.id, %{title: "Second"}, actor: user)
      {:ok, _t3} = Plan.create_task(conversation.id, %{title: "Third"}, actor: user)

      {:ok, tasks} = Plan.tasks_for_conversation(conversation.id, actor: user)

      titles = Enum.map(tasks, & &1.title)
      assert titles == ["First", "Second", "Third"]
    end

    test "scopes tasks to the given conversation" do
      %{user: user, conversation: conv1} = create_context()
      {:ok, conv2} = Chat.create_conversation(%{}, actor: user)

      {:ok, _} = Plan.create_task(conv1.id, %{title: "Conv1 Task"}, actor: user)
      {:ok, _} = Plan.create_task(conv2.id, %{title: "Conv2 Task"}, actor: user)

      {:ok, conv1_tasks} = Plan.tasks_for_conversation(conv1.id, actor: user)

      assert length(conv1_tasks) == 1
      assert hd(conv1_tasks).title == "Conv1 Task"
    end

    test "returns empty list when no tasks exist" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, tasks} = Plan.tasks_for_conversation(conversation.id, actor: user)

      assert tasks == []
    end
  end

  # ---------------------------------------------------------------------------
  # Due dates
  # ---------------------------------------------------------------------------

  describe "due dates" do
    test "creates task with due_at" do
      %{user: user, conversation: conversation} = create_context()
      due = DateTime.add(DateTime.utc_now(), 86400, :second)

      task =
        Plan.create_task!(conversation.id, %{title: "Practice figure drawing", due_at: due},
          actor: user
        )

      assert task.due_at != nil
      assert DateTime.diff(task.due_at, due) == 0
    end

    test "creates task without due_at" do
      %{user: user, conversation: conversation} = create_context()
      task = Plan.create_task!(conversation.id, %{title: "No deadline"}, actor: user)
      assert task.due_at == nil
    end

    test "updates task due_at" do
      %{user: user, conversation: conversation} = create_context()
      task = Plan.create_task!(conversation.id, %{title: "Do the thing"}, actor: user)
      due = DateTime.add(DateTime.utc_now(), 172_800, :second)
      updated = Plan.update_task!(task, %{due_at: due}, actor: user)
      assert updated.due_at != nil
    end
  end

  # ---------------------------------------------------------------------------
  # open_for_user + complete/dismiss (startpage affordances)
  # ---------------------------------------------------------------------------

  describe "open_tasks_for_user" do
    test "returns open tasks assigned to the user" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, _task} =
        Plan.create_task(
          conversation.id,
          %{title: "Assigned task", assigned_to_user_id: user.id},
          actor: user
        )

      {:ok, tasks} = Plan.open_tasks_for_user(user.id, actor: user)

      assert Enum.map(tasks, & &1.title) == ["Assigned task"]
    end

    test "excludes tasks not assigned to the user" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, _task} = Plan.create_task(conversation.id, %{title: "Unassigned"}, actor: user)

      {:ok, tasks} = Plan.open_tasks_for_user(user.id, actor: user)

      assert tasks == []
    end
  end

  describe "complete (check off)" do
    test "sets status to done, completed_by user, and drops from open_for_user" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} =
        Plan.create_task(
          conversation.id,
          %{title: "Check me off", assigned_to_user_id: user.id},
          actor: user
        )

      {:ok, completed} = Plan.complete_task(task, actor: user)

      assert completed.status == :done
      assert completed.completed_by == "user"

      {:ok, tasks} = Plan.open_tasks_for_user(user.id, actor: user)
      refute Enum.any?(tasks, &(&1.id == task.id))
    end
  end

  describe "dismiss (startpage-scoped hide)" do
    test "sets dismissed_at, keeps status open, drops from open_for_user but stays in conversation" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, task} =
        Plan.create_task(
          conversation.id,
          %{title: "Dismiss me", assigned_to_user_id: user.id},
          actor: user
        )

      {:ok, dismissed} = Plan.dismiss_task(task, actor: user)

      assert dismissed.dismissed_at != nil
      assert dismissed.status == :open

      {:ok, open_tasks} = Plan.open_tasks_for_user(user.id, actor: user)
      refute Enum.any?(open_tasks, &(&1.id == task.id))

      # Startpage-scoped: still visible in the conversation's task pane.
      {:ok, conv_tasks} = Plan.tasks_for_conversation(conversation.id, actor: user)
      assert Enum.any?(conv_tasks, &(&1.id == task.id))
    end
  end

  # ---------------------------------------------------------------------------
  # TaskPaneState dismiss/reopen cycle
  # ---------------------------------------------------------------------------

  describe "TaskPaneState" do
    test "dismiss creates a pane state with pane_open false" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, state} =
        Plan.dismiss_task_pane(conversation.id, user.id, actor: user)

      assert state.pane_open == false
      assert state.conversation_id == conversation.id
      assert state.user_id == user.id
    end

    test "reopen creates a pane state with pane_open true" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, state} =
        Plan.reopen_task_pane(conversation.id, user.id, actor: user)

      assert state.pane_open == true
    end

    test "dismiss then reopen sets pane_open to true (upsert)" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, _} = Plan.dismiss_task_pane(conversation.id, user.id, actor: user)
      {:ok, reopened} = Plan.reopen_task_pane(conversation.id, user.id, actor: user)

      assert reopened.pane_open == true
    end

    test "reopen then dismiss sets pane_open to false (upsert)" do
      %{user: user, conversation: conversation} = create_context()

      {:ok, _} = Plan.reopen_task_pane(conversation.id, user.id, actor: user)
      {:ok, dismissed} = Plan.dismiss_task_pane(conversation.id, user.id, actor: user)

      assert dismissed.pane_open == false
    end

    test "pane state is scoped per user per conversation" do
      %{user: user1, conversation: conversation} = create_context()
      user2 = generate(user())

      {:ok, conversation} = Chat.enable_multiplayer(conversation, actor: user1)
      {:ok, invite} = Chat.add_conversation_member(conversation.id, user2.id, actor: user1)
      {:ok, _} = Chat.accept_conversation_invitation(invite, actor: user2)

      {:ok, _} = Plan.dismiss_task_pane(conversation.id, user1.id, actor: user1)
      {:ok, state2} = Plan.reopen_task_pane(conversation.id, user2.id, actor: user2)

      assert state2.pane_open == true
    end
  end
end
