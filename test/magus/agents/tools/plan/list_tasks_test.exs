defmodule Magus.Agents.Tools.Plan.ListTasksTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Plan.{CreateTask, UpdateTask, ListTasks}
  alias Magus.Chat

  defp create_test_context do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

    %{
      user: user,
      conversation: conversation,
      context: %{
        user_id: user.id,
        conversation_id: conversation.id
      }
    }
  end

  describe "display_name/0 and summarize_output/1" do
    test "provides display name" do
      assert ListTasks.display_name() == "Listing tasks..."
    end

    test "summarizes with summary string" do
      assert ListTasks.summarize_output(%{summary: "3 tasks (1 done, 2 open)"}) ==
               "3 tasks (1 done, 2 open)"
    end

    test "summarizes error output" do
      assert ListTasks.summarize_output(%{error: "failed"}) == "Error"
    end
  end

  describe "run/2 - empty list" do
    test "returns empty tasks for a new conversation" do
      %{context: context} = create_test_context()

      assert {:ok, result} = ListTasks.run(%{}, context)
      assert result.tasks == []
      assert result.summary == "0 tasks"
    end
  end

  describe "run/2 - listing tasks" do
    test "returns all top-level tasks" do
      %{context: context} = create_test_context()

      CreateTask.run(%{"title" => "Task A"}, context)
      CreateTask.run(%{"title" => "Task B"}, context)

      assert {:ok, result} = ListTasks.run(%{}, context)
      assert length(result.tasks) == 2
      titles = Enum.map(result.tasks, & &1.title)
      assert "Task A" in titles
      assert "Task B" in titles
    end

    test "groups subtasks under their parent" do
      %{context: context} = create_test_context()

      {:ok, parent} = CreateTask.run(%{"title" => "Parent"}, context)
      CreateTask.run(%{"title" => "Child 1", "parent_id" => parent.task_id}, context)
      CreateTask.run(%{"title" => "Child 2", "parent_id" => parent.task_id}, context)

      assert {:ok, result} = ListTasks.run(%{}, context)

      # Only the parent is at top level
      assert length(result.tasks) == 1
      [parent_task] = result.tasks
      assert parent_task.title == "Parent"
      assert length(parent_task.subtasks) == 2

      subtask_titles = Enum.map(parent_task.subtasks, & &1.title)
      assert "Child 1" in subtask_titles
      assert "Child 2" in subtask_titles
    end

    test "includes status and assignment info" do
      %{context: context} = create_test_context()

      CreateTask.run(%{"title" => "Assigned", "assigned_to" => "user"}, context)

      assert {:ok, result} = ListTasks.run(%{}, context)
      [task] = result.tasks
      assert task.status == :open
      assert task.assigned_to == "user"
    end

    test "includes completed_by after marking done" do
      %{context: context} = create_test_context()

      {:ok, created} = CreateTask.run(%{"title" => "Complete me"}, context)
      UpdateTask.run(%{"task_id" => created.task_id, "status" => "done"}, context)

      assert {:ok, result} = ListTasks.run(%{}, context)
      [task] = result.tasks
      assert task.status == :done
      assert task.completed_by != nil
    end
  end

  describe "run/2 - summary" do
    test "summary counts tasks by status" do
      %{context: context} = create_test_context()

      {:ok, t1} = CreateTask.run(%{"title" => "Open 1"}, context)
      {:ok, t2} = CreateTask.run(%{"title" => "Done 1"}, context)
      CreateTask.run(%{"title" => "In progress 1"}, context)

      UpdateTask.run(%{"task_id" => t2.task_id, "status" => "done"}, context)

      UpdateTask.run(
        %{"task_id" => t1.task_id, "status" => "in_progress"},
        context
      )

      assert {:ok, result} = ListTasks.run(%{}, context)
      assert result.summary =~ "3 tasks"
      assert result.summary =~ "done"
      assert result.summary =~ "in progress"
    end

    test "summary for all-open tasks" do
      %{context: context} = create_test_context()

      CreateTask.run(%{"title" => "Open 1"}, context)
      CreateTask.run(%{"title" => "Open 2"}, context)

      assert {:ok, result} = ListTasks.run(%{}, context)
      assert result.summary == "2 tasks (2 open)"
    end
  end

  describe "run/2 - error handling" do
    test "returns error when conversation_id is missing" do
      assert {:ok, result} = ListTasks.run(%{}, %{})
      assert result.error =~ "Missing required context"
    end

    test "tasks are scoped to conversation" do
      %{context: context1} = create_test_context()
      %{context: context2} = create_test_context()

      CreateTask.run(%{"title" => "Conv1 task"}, context1)
      CreateTask.run(%{"title" => "Conv2 task"}, context2)

      assert {:ok, result1} = ListTasks.run(%{}, context1)
      assert {:ok, result2} = ListTasks.run(%{}, context2)

      assert length(result1.tasks) == 1
      assert length(result2.tasks) == 1
      assert hd(result1.tasks).title == "Conv1 task"
      assert hd(result2.tasks).title == "Conv2 task"
    end
  end
end
