defmodule Magus.Agents.Tools.Plan.UpdateTaskTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Plan.{CreateTask, UpdateTask}
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

  defp create_task(context, attrs \\ %{}) do
    params = Map.merge(%{"title" => "Test task"}, attrs)
    {:ok, result} = CreateTask.run(params, context)
    result
  end

  describe "display_name/0 and summarize_output/1" do
    test "provides display name" do
      assert UpdateTask.display_name() == "Updating task..."
    end

    test "summarizes output with title and status" do
      assert UpdateTask.summarize_output(%{title: "Deploy", status: :done}) ==
               "Updated: Deploy (done)"
    end

    test "summarizes output with title only" do
      assert UpdateTask.summarize_output(%{title: "Deploy"}) == "Updated: Deploy"
    end

    test "summarizes error output" do
      assert UpdateTask.summarize_output(%{error: "not found"}) == "Error"
    end
  end

  describe "run/2 - update status" do
    test "updates status from open to in_progress" do
      %{context: context} = create_test_context()
      task = create_task(context)

      assert {:ok, result} =
               UpdateTask.run(%{"task_id" => task.task_id, "status" => "in_progress"}, context)

      assert result.status == :in_progress
    end

    test "updates status to done" do
      %{context: context} = create_test_context()
      task = create_task(context)

      assert {:ok, result} =
               UpdateTask.run(%{"task_id" => task.task_id, "status" => "done"}, context)

      assert result.status == :done
    end

    test "updates status to cancelled" do
      %{context: context} = create_test_context()
      task = create_task(context)

      assert {:ok, result} =
               UpdateTask.run(%{"task_id" => task.task_id, "status" => "cancelled"}, context)

      assert result.status == :cancelled
    end
  end

  describe "run/2 - completed_by" do
    test "sets completed_by when status is set to done" do
      %{context: context} = create_test_context()
      task = create_task(context)

      assert {:ok, result} =
               UpdateTask.run(%{"task_id" => task.task_id, "status" => "done"}, context)

      assert result.completed_by != nil
    end

    test "completed_by is nil for non-done status" do
      %{context: context} = create_test_context()
      task = create_task(context)

      assert {:ok, result} =
               UpdateTask.run(
                 %{"task_id" => task.task_id, "status" => "in_progress"},
                 context
               )

      assert result.completed_by == nil
    end
  end

  describe "run/2 - update title and description" do
    test "updates title" do
      %{context: context} = create_test_context()
      task = create_task(context)

      assert {:ok, result} =
               UpdateTask.run(%{"task_id" => task.task_id, "title" => "New title"}, context)

      assert result.title == "New title"
    end
  end

  describe "run/2 - assignment" do
    test "assigns to user" do
      %{context: context} = create_test_context()
      task = create_task(context)

      assert {:ok, result} =
               UpdateTask.run(
                 %{"task_id" => task.task_id, "assigned_to" => "user"},
                 context
               )

      assert result.assigned_to == "user"
    end
  end

  describe "run/2 - cross-conversation security" do
    test "rejects update for task in a different conversation" do
      %{context: context1} = create_test_context()
      %{context: context2} = create_test_context()

      task = create_task(context1)

      assert {:ok, result} =
               UpdateTask.run(%{"task_id" => task.task_id, "status" => "done"}, context2)

      assert result.error =~ "not found"
    end
  end

  describe "run/2 - error handling" do
    test "returns error for non-existent task" do
      %{context: context} = create_test_context()
      fake_id = Ash.UUIDv7.generate()

      assert {:ok, result} =
               UpdateTask.run(%{"task_id" => fake_id, "status" => "done"}, context)

      assert result.error =~ "not found"
    end

    test "returns error when context is missing" do
      assert {:ok, result} =
               UpdateTask.run(%{"task_id" => Ash.UUIDv7.generate()}, %{})

      assert result.error =~ "Missing required context"
    end
  end
end
