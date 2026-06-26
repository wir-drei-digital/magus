defmodule MagusWeb.Workbench.Chat.NewChatOpenTasksTest do
  @moduledoc """
  Tests for the "Your open tasks" affordances on the new-chat startpage
  (rendered by ConversationView in its `conversation_id => "new"` mode).

  Covers check-off (complete) and dismiss (startpage-scoped hide).
  """
  use MagusWeb.LiveViewCase, async: false

  import Magus.Generators
  import MagusWeb.Workbench.TestHelpers

  alias MagusWeb.Workbench.Resources.ConversationView

  defp setup_user_with_open_task do
    user = generate(user())
    ensure_workspace_plan(user)

    {:ok, conv} =
      Magus.Chat.create_conversation(%{title: "Startpage tasks"}, actor: user)

    {:ok, task} =
      Magus.Plan.create_task(
        conv.id,
        %{title: "Open startpage task", assigned_to_user_id: user.id},
        actor: user
      )

    {user, conv, task}
  end

  defp mount_new_chat(user) do
    Phoenix.LiveViewTest.live_isolated(
      Phoenix.ConnTest.build_conn(),
      ConversationView,
      session: %{
        "conversation_id" => "new",
        "user_id" => user.id,
        "tab_id" => "tab_new_chat_tasks"
      }
    )
  end

  # The open-tasks list loads asynchronously post-connect. Wait until the row
  # shows up before interacting with it.
  defp wait_for_task_row(lv, task) do
    poll_until(fn ->
      Phoenix.LiveViewTest.render(lv) =~ "open-task-#{task.id}"
    end)
  end

  describe "open tasks on the startpage" do
    test "renders an assigned open task with a structural row id" do
      {user, _conv, task} = setup_user_with_open_task()

      {:ok, lv, _html} = mount_new_chat(user)

      wait_for_task_row(lv, task)
      assert Phoenix.LiveViewTest.render(lv) =~ "open-task-#{task.id}"
    end

    test "dismissing a task removes the row and sets dismissed_at in the DB" do
      {user, _conv, task} = setup_user_with_open_task()

      {:ok, lv, _html} = mount_new_chat(user)
      wait_for_task_row(lv, task)

      html = render_click(lv, "dismiss_open_task", %{"id" => task.id})

      refute html =~ "open-task-#{task.id}"

      {:ok, reloaded} = Magus.Plan.get_task(task.id, actor: user)
      assert reloaded.dismissed_at != nil
      assert reloaded.status == :open
    end

    test "checking off a task removes the row and marks it done in the DB" do
      {user, _conv, task} = setup_user_with_open_task()

      {:ok, lv, _html} = mount_new_chat(user)
      wait_for_task_row(lv, task)

      html = render_click(lv, "complete_open_task", %{"id" => task.id})

      refute html =~ "open-task-#{task.id}"

      {:ok, reloaded} = Magus.Plan.get_task(task.id, actor: user)
      assert reloaded.status == :done
      assert reloaded.completed_by == "user"
    end
  end
end
