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

  # ---------------------------------------------------------------------------
  # Brain page tasks (page-keyed boards)
  # ---------------------------------------------------------------------------

  defp create_page_context do
    %{user: user, conversation: conversation, context: context} = create_test_context()
    {:ok, brain} = Magus.Brain.create_brain(%{title: "Task Brain"}, actor: user)
    {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Project Alpha"}, actor: user)

    %{
      user: user,
      conversation: conversation,
      brain: brain,
      page: page,
      # The page path resolves and creates AS THE USER, so the context must
      # carry the user struct (as the real tool context does).
      context: Map.put(context, :user, user)
    }
  end

  describe "run/2 - brain page tasks" do
    test "creates a task on the page's board by page id" do
      %{context: context, page: page, user: user, conversation: conversation} =
        create_page_context()

      assert {:ok, result} =
               CreateTask.run(%{"title" => "Ship it", "brain_page_id" => page.id}, context)

      assert result.brain_page_id == page.id
      assert result.page_title == "Project Alpha"

      {:ok, board} = Magus.Plan.tasks_for_plan(page.id, actor: user)
      assert Enum.any?(board, &(&1.title == "Ship it"))

      # NOT in the conversation list.
      {:ok, conv_tasks} = Magus.Plan.tasks_for_conversation(conversation.id, actor: user)
      refute Enum.any?(conv_tasks, &(&1.title == "Ship it"))
    end

    test "resolves the page by exact title" do
      %{context: context, page: page, user: user} = create_page_context()

      assert {:ok, result} =
               CreateTask.run(
                 %{"title" => "By title", "brain_page_id" => "Project Alpha"},
                 context
               )

      assert result.brain_page_id == page.id

      {:ok, board} = Magus.Plan.tasks_for_plan(page.id, actor: user)
      assert Enum.any?(board, &(&1.title == "By title"))
    end

    test "batch creation lands every task on the page board in order" do
      %{context: context, page: page, user: user} = create_page_context()

      assert {:ok, result} =
               CreateTask.run(
                 %{
                   "brain_page_id" => page.id,
                   "tasks" => [%{"title" => "First"}, %{"title" => "Second"}]
                 },
                 context
               )

      assert length(result.created) == 2
      assert result.brain_page_id == page.id

      {:ok, board} = Magus.Plan.tasks_for_plan(page.id, actor: user)
      assert Enum.map(board, & &1.title) == ["First", "Second"]
    end

    test "another user's page is not reachable" do
      %{context: context} = create_page_context()

      stranger = generate(user())
      {:ok, other_brain} = Magus.Brain.create_brain(%{title: "Private"}, actor: stranger)

      {:ok, other_page} =
        Magus.Brain.create_page(other_brain.id, %{title: "Secret"}, actor: stranger)

      assert {:ok, %{error: error}} =
               CreateTask.run(
                 %{"title" => "Sneaky", "brain_page_id" => other_page.id},
                 context
               )

      assert is_binary(error)

      {:ok, board} = Magus.Plan.tasks_for_plan(other_page.id, actor: stranger)
      assert board == []
    end

    test "clear_previous never touches a page board (note, conversation intact)" do
      %{context: context, page: page, conversation: conversation, user: user} =
        create_page_context()

      # Seed one conversation task and one page task.
      assert {:ok, _} = CreateTask.run(%{"title" => "Conv task"}, context)

      assert {:ok, result} =
               CreateTask.run(
                 %{
                   "title" => "Page task",
                   "brain_page_id" => page.id,
                   "clear_previous" => true
                 },
                 context
               )

      assert result.note =~ "conversation tasks only"

      # The conversation task survived (clear_previous was NOT applied).
      {:ok, conv_tasks} = Magus.Plan.tasks_for_conversation(conversation.id, actor: user)
      assert Enum.any?(conv_tasks, &(&1.title == "Conv task"))
    end

    test "a blank brain_page_id falls back to a conversation task" do
      %{context: context, conversation: conversation, user: user} = create_page_context()

      assert {:ok, result} =
               CreateTask.run(%{"title" => "Plain", "brain_page_id" => ""}, context)

      refute Map.has_key?(result, :brain_page_id)

      {:ok, conv_tasks} = Magus.Plan.tasks_for_conversation(conversation.id, actor: user)
      assert Enum.any?(conv_tasks, &(&1.title == "Plain"))
    end
  end
end
