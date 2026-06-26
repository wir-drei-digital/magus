defmodule Magus.Agents.Tools.Plan.CreateTaskTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Plan.CreateTask
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
      assert CreateTask.display_name() == "Creating task..."
    end

    test "summarizes created output" do
      assert CreateTask.summarize_output(%{title: "My Task"}) == "Created: My Task"
    end

    test "summarizes error output" do
      assert CreateTask.summarize_output(%{error: "something went wrong"}) == "Error"
    end
  end

  describe "run/2 - create top-level task" do
    test "creates a top-level task with title only" do
      %{context: context} = create_test_context()

      params = %{"title" => "Write tests"}

      assert {:ok, result} = CreateTask.run(params, context)
      assert result.task_id != nil
      assert result.title == "Write tests"
      assert result.status == :open
      assert result.parent_id == nil
      assert result.position != nil
    end

    test "creates task with description" do
      %{context: context} = create_test_context()

      params = %{"title" => "Deploy app", "description" => "Push to production"}

      assert {:ok, result} = CreateTask.run(params, context)
      assert result.title == "Deploy app"
    end

    test "creates task with explicit status" do
      %{context: context} = create_test_context()

      params = %{"title" => "In flight", "status" => "in_progress"}

      assert {:ok, result} = CreateTask.run(params, context)
      assert result.status == :in_progress
    end

    test "creates task with done status" do
      %{context: context} = create_test_context()

      params = %{"title" => "Already done", "status" => "done"}

      assert {:ok, result} = CreateTask.run(params, context)
      assert result.status == :done
    end
  end

  describe "run/2 - create subtask" do
    test "creates a subtask under a parent" do
      %{context: context} = create_test_context()

      {:ok, parent} = CreateTask.run(%{"title" => "Parent task"}, context)

      params = %{"title" => "Child task", "parent_id" => parent.task_id}

      assert {:ok, result} = CreateTask.run(params, context)
      assert result.title == "Child task"
      assert result.parent_id == parent.task_id
    end
  end

  describe "run/2 - assignment" do
    test "assigns task to user when assigned_to is 'user'" do
      %{context: context} = create_test_context()

      params = %{"title" => "User task", "assigned_to" => "user"}

      assert {:ok, result} = CreateTask.run(params, context)
      assert result.assigned_to == "user"
    end

    test "defaults to agent assignment when assigned_to is nil" do
      %{context: context} = create_test_context()

      params = %{"title" => "Default assignment task"}

      assert {:ok, result} = CreateTask.run(params, context)
      assert result.assigned_to == "agent"
    end
  end

  describe "run/2 - error handling" do
    test "returns error when conversation_id is missing" do
      context = %{user_id: Ash.UUIDv7.generate()}

      assert {:ok, result} = CreateTask.run(%{"title" => "Task"}, context)
      assert result.error =~ "Missing required context"
    end

    test "returns error when context is empty" do
      assert {:ok, result} = CreateTask.run(%{"title" => "Task"}, %{})
      assert result.error =~ "Missing required context"
    end

    test "works with string keys in context" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      string_context = %{
        "user_id" => user.id,
        "conversation_id" => conversation.id
      }

      assert {:ok, result} = CreateTask.run(%{"title" => "String key task"}, string_context)
      assert result.title == "String key task"
    end
  end
end
