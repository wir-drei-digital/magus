defmodule MagusWeb.Workbench.Resources.ConversationViewTasksTest do
  use MagusWeb.LiveViewCase, async: false

  import Magus.Generators
  import MagusWeb.Workbench.TestHelpers

  alias MagusWeb.Workbench.Resources.ConversationView

  defp setup_conversation_with_task do
    user = generate(user())
    ensure_workspace_plan(user)
    ws = generate(workspace(actor: user))

    {:ok, conv} =
      Magus.Chat.create_conversation(
        %{title: "Inline tasks test", workspace_id: ws.id},
        actor: user
      )

    {:ok, task} =
      Magus.Plan.create_task(conv.id, %{title: "Buy milk"}, actor: user)

    {user, conv, task}
  end

  defp mount_view(user, conv) do
    Phoenix.LiveViewTest.live_isolated(
      Phoenix.ConnTest.build_conn(),
      ConversationView,
      session: %{
        "conversation_id" => conv.id,
        "user_id" => user.id,
        "tab_id" => "tab_tasks_test"
      }
    )
  end

  describe "inline task pane" do
    test "renders the collapsed header with task count on mount" do
      {user, conv, _task} = setup_conversation_with_task()

      {:ok, _lv, html} = mount_view(user, conv)

      # The pane is collapsed by default; the count is the visible signal.
      assert html =~ "0/1"
    end

    test "clicking the checkbox marks the task done in the DB" do
      {user, conv, task} = setup_conversation_with_task()

      {:ok, lv, _html} = mount_view(user, conv)

      # TaskPaneComponent sends a tuple message to its parent process via
      # send(self(), {TaskPaneComponent, ...}). Simulate that directly.
      send(
        lv.pid,
        {MagusWeb.ChatLive.Components.Tasks.TaskPaneComponent, {:toggle_task, task.id}}
      )

      :ok =
        poll_until(fn ->
          {:ok, reloaded} = Magus.Plan.get_task(task.id, actor: user)
          reloaded.status == :done
        end)

      # And the in-memory list is updated too: count becomes 1/1.
      assert Phoenix.LiveViewTest.render(lv) =~ "1/1"
    end

    test "task.created broadcast appears in the inline list" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, conv} =
        Magus.Chat.create_conversation(
          %{title: "Broadcast test", workspace_id: ws.id},
          actor: user
        )

      {:ok, lv, html} = mount_view(user, conv)

      # No tasks yet, so the inline pane is hidden entirely.
      refute html =~ "0/0"

      {:ok, task} =
        Magus.Plan.create_task(conv.id, %{title: "Pushed task"}, actor: user)

      send(lv.pid, %Phoenix.Socket.Broadcast{
        topic: "tasks:conversation:#{conv.id}",
        event: "task.created",
        payload: %{task: task}
      })

      :ok = poll_until(fn -> Phoenix.LiveViewTest.render(lv) =~ "0/1" end)
    end
  end
end
