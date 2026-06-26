defmodule Magus.Agents.Tools.Tasks.CompleteTaskTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.Tools.Tasks.CompleteTask

  require Ash.Query

  setup do
    user = generate(user())
    parent = generate(conversation(actor: user))

    child =
      generate(
        conversation(
          actor: user,
          is_task_conversation: true,
          parent_conversation_id: parent.id
        )
      )

    # Create an active job in the child conversation
    active_job =
      job(
        conversation_id: child.id,
        user_id: user.id,
        name: "task_run",
        schedule_type: :cron,
        cron_expression: "0 */2 * * *",
        ends_at: DateTime.add(DateTime.utc_now(), 30, :day)
      )

    context = %{
      conversation_id: child.id,
      user_id: user.id
    }

    %{user: user, parent: parent, child: child, active_job: active_job, context: context}
  end

  describe "run/2" do
    test "stops active jobs in task conversation", %{context: context, child: child} do
      {:ok, result} =
        CompleteTask.run(%{"summary" => "All done"}, context)

      assert result.completed == true

      {:ok, all_jobs} =
        Magus.Workflows.list_all_jobs_for_conversation(child.id,
          actor: %Magus.Agents.Support.AiAgent{}
        )

      assert Enum.all?(all_jobs, &(&1.status == :stopped))
    end

    test "creates event message in parent conversation", %{context: context, parent: parent} do
      {:ok, _result} =
        CompleteTask.run(%{"summary" => "Found the best deal"}, context)

      messages =
        Magus.Chat.Message
        |> Ash.Query.filter(conversation_id == ^parent.id and message_type == :event)
        |> Ash.read!(authorize?: false)

      assert Enum.any?(messages, &(&1.text =~ "Found the best deal"))
    end

    test "creates notification for user", %{context: context, user: user} do
      {:ok, _result} =
        CompleteTask.run(%{"summary" => "Research complete"}, context)

      {:ok, notifications} =
        Magus.Notifications.list_unread_notifications(actor: user)

      assert Enum.any?(notifications, &(&1.notification_type == :task_completed))
      assert Enum.any?(notifications, &(&1.body =~ "Research complete"))
    end

    test "works without parent conversation", %{user: user} do
      orphan = generate(conversation(actor: user, is_task_conversation: true))

      context = %{
        conversation_id: orphan.id,
        user_id: user.id
      }

      {:ok, result} =
        CompleteTask.run(%{"summary" => "Done anyway"}, context)

      assert result.completed == true
    end
  end
end
