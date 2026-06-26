defmodule Magus.Agents.Tools.Tasks.SpawnTaskTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.Tools.Tasks.SpawnTask

  require Ash.Query

  setup do
    user = generate(user())
    conversation = generate(conversation(actor: user))
    user = Ash.load!(user, [], authorize?: false)

    context = %{
      conversation_id: conversation.id,
      user_id: user.id,
      user: user
    }

    %{user: user, conversation: conversation, context: context}
  end

  describe "run/2" do
    test "creates child task conversation with parent link", %{
      context: context,
      conversation: parent
    } do
      {:ok, result} =
        SpawnTask.run(
          %{"objective" => "Monitor flight prices", "delay_minutes" => 5},
          context
        )

      assert result.status == "spawned"
      assert result.task_conversation_id

      {:ok, child} = Magus.Chat.get_conversation(result.task_conversation_id, authorize?: false)
      assert child.is_task_conversation == true
      assert child.parent_conversation_id == parent.id
      assert child.system_prompt =~ "Monitor flight prices"
    end

    test "creates a Job in the child conversation", %{context: context} do
      {:ok, result} =
        SpawnTask.run(
          %{"objective" => "Check weather", "delay_minutes" => 10},
          context
        )

      {:ok, jobs} =
        Magus.Workflows.list_jobs_for_conversation(result.task_conversation_id,
          actor: %Magus.Agents.Support.AiAgent{}
        )

      assert length(jobs) == 1
      job = hd(jobs)
      assert job.name == "task_run"
      assert job.schedule_type == :one_time
      assert job.trigger_prompt == "Check weather"
    end

    test "creates cron Job when schedule provided", %{context: context} do
      {:ok, result} =
        SpawnTask.run(
          %{"objective" => "Daily digest", "schedule" => "0 9 * * *"},
          context
        )

      assert result.schedule_type == "cron"

      {:ok, jobs} =
        Magus.Workflows.list_jobs_for_conversation(result.task_conversation_id,
          actor: %Magus.Agents.Support.AiAgent{}
        )

      job = hd(jobs)
      assert job.schedule_type == :cron
      assert job.cron_expression == "0 9 * * *"
    end

    test "posts event message to parent conversation", %{context: context, conversation: parent} do
      {:ok, _result} =
        SpawnTask.run(
          %{"objective" => "Research topic"},
          context
        )

      messages =
        Magus.Chat.Message
        |> Ash.Query.filter(conversation_id == ^parent.id and message_type == :event)
        |> Ash.read!(authorize?: false)

      assert Enum.any?(messages, &(&1.text =~ "Research topic"))
    end

    test "respects concurrent task limit", %{user: user, context: context} do
      # Create 10 task conversations to hit the limit
      for _i <- 1..10 do
        generate(conversation(actor: user, is_task_conversation: true))
      end

      {:ok, result} =
        SpawnTask.run(
          %{"objective" => "This should fail"},
          context
        )

      assert result.error =~ "maximum"
    end

    test "defaults to 1 minute delay when no schedule given", %{context: context} do
      {:ok, result} =
        SpawnTask.run(
          %{"objective" => "Quick task"},
          context
        )

      {:ok, jobs} =
        Magus.Workflows.list_jobs_for_conversation(result.task_conversation_id,
          actor: %Magus.Agents.Support.AiAgent{}
        )

      job = hd(jobs)
      assert job.schedule_type == :one_time
      diff = DateTime.diff(job.scheduled_at, DateTime.utc_now(), :second)
      assert diff >= 50 and diff <= 70
    end

    test "task conversation inherits workspace_id from tool context", %{user: user} do
      ensure_workspace_plan(user)

      workspace =
        Magus.Workspaces.create_workspace!(
          %{name: "Test WS", slug: "ws-#{System.unique_integer([:positive])}"},
          actor: user
        )

      parent =
        Magus.Chat.create_conversation!(
          %{title: "Parent", workspace_id: workspace.id},
          actor: user
        )

      context = %{
        conversation_id: parent.id,
        user_id: user.id,
        user: user,
        workspace_id: workspace.id
      }

      assert {:ok, result} =
               SpawnTask.run(%{"objective" => "Monitor prices"}, context)

      assert result.status == "spawned"

      task_conv =
        Magus.Chat.Conversation
        |> Ash.Query.filter(parent_conversation_id == ^parent.id)
        |> Ash.read_one!(authorize?: false)

      assert task_conv.workspace_id == workspace.id
    end

    test "task conversation has no workspace_id when context has none", %{
      context: context,
      conversation: parent
    } do
      assert {:ok, result} =
               SpawnTask.run(%{"objective" => "Quick check"}, context)

      assert result.status == "spawned"

      task_conv =
        Magus.Chat.Conversation
        |> Ash.Query.filter(parent_conversation_id == ^parent.id)
        |> Ash.read_one!(authorize?: false)

      assert is_nil(task_conv.workspace_id)
    end
  end
end
