defmodule Magus.Agents.Context.TaskContextTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Agents.Context.TaskContext
  alias Magus.Plan

  setup do
    user = generate(user())
    conversation = generate(conversation(actor: user))
    %{user: user, conversation: conversation}
  end

  describe "build/1" do
    test "returns nil when no tasks", %{conversation: conversation} do
      assert TaskContext.build(conversation.id) == nil
    end

    test "returns nil for nil input" do
      assert TaskContext.build(nil) == nil
    end

    test "returns nil for non-binary input" do
      assert TaskContext.build(123) == nil
    end

    test "renders open task with checkbox unchecked", %{user: user, conversation: conversation} do
      {:ok, _task} =
        Plan.create_task(conversation.id, %{title: "Write the report"}, authorize?: false)

      result = TaskContext.build(conversation.id, actor: user)

      assert result =~ "## Tasks"
      assert result =~ "- [ ] Write the report"
    end

    test "renders done task with checkbox checked", %{user: user, conversation: conversation} do
      {:ok, task} =
        Plan.create_task(conversation.id, %{title: "Deploy app"}, authorize?: false)

      {:ok, _task} = Plan.update_task(task, %{status: :done}, authorize?: false)

      result = TaskContext.build(conversation.id, actor: user)

      assert result =~ "- [x] Deploy app"
    end

    test "shows @agent for agent-assigned tasks", %{user: user, conversation: conversation} do
      {:ok, _task} =
        Plan.create_task(
          conversation.id,
          %{title: "Research competitors", assigned_to_agent: "agent"},
          authorize?: false
        )

      result = TaskContext.build(conversation.id, actor: user)

      assert result =~ "@agent"
    end

    test "shows @user for user-assigned tasks", %{user: user, conversation: conversation} do
      {:ok, _task} =
        Plan.create_task(
          conversation.id,
          %{title: "Review draft", assigned_to_user_id: user.id},
          authorize?: false
        )

      result = TaskContext.build(conversation.id, actor: user)

      assert result =~ "@user"
    end

    test "shows (in progress) for in_progress tasks", %{user: user, conversation: conversation} do
      {:ok, task} =
        Plan.create_task(conversation.id, %{title: "Write first draft"}, authorize?: false)

      {:ok, _task} = Plan.update_task(task, %{status: :in_progress}, authorize?: false)

      result = TaskContext.build(conversation.id, actor: user)

      assert result =~ "- [ ] Write first draft"
      assert result =~ "in progress"
    end

    test "shows (cancelled) for cancelled tasks", %{user: user, conversation: conversation} do
      {:ok, task} =
        Plan.create_task(conversation.id, %{title: "Old idea"}, authorize?: false)

      {:ok, _task} = Plan.update_task(task, %{status: :cancelled}, authorize?: false)

      result = TaskContext.build(conversation.id, actor: user)

      assert result =~ "- [ ] Old idea"
      assert result =~ "cancelled"
    end

    test "shows completed_by on done tasks", %{user: user, conversation: conversation} do
      {:ok, task} =
        Plan.create_task(
          conversation.id,
          %{title: "Research competitors", assigned_to_agent: "agent"},
          authorize?: false
        )

      # SetCompletedBy change sets completed_by to "agent" when actor is not a User
      {:ok, _task} =
        Plan.update_task(task, %{status: :done}, authorize?: false)

      result = TaskContext.build(conversation.id, actor: user)

      assert result =~ "completed by agent"
    end

    test "renders subtasks indented under parent", %{user: user, conversation: conversation} do
      {:ok, parent} =
        Plan.create_task(conversation.id, %{title: "Write first draft"}, authorize?: false)

      {:ok, _subtask} =
        Plan.create_task(
          conversation.id,
          %{title: "Introduction section", parent_id: parent.id},
          authorize?: false
        )

      {:ok, _subtask2} =
        Plan.create_task(
          conversation.id,
          %{title: "Main body", parent_id: parent.id},
          authorize?: false
        )

      result = TaskContext.build(conversation.id, actor: user)

      assert result =~ "- [ ] Write first draft"
      assert result =~ "  - [ ] Introduction section"
      assert result =~ "  - [ ] Main body"
    end

    test "includes tool usage hint", %{user: user, conversation: conversation} do
      {:ok, _task} =
        Plan.create_task(conversation.id, %{title: "Do something"}, authorize?: false)

      result = TaskContext.build(conversation.id, actor: user)

      assert result =~ "create_task"
      assert result =~ "update_task"
      assert result =~ "list_tasks"
      assert result =~ "task pane"
    end
  end
end
