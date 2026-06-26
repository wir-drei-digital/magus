defmodule MagusWeb.Workbench.Detail.HistoryViewTest do
  use MagusWeb.LiveViewCase, async: false

  import Phoenix.LiveViewTest
  import MagusWeb.LiveViewCase
  import Magus.Generators

  describe "GET /history" do
    setup %{conn: conn} do
      user = generate(user())
      %{conn: log_in_user(conn, user), user: user}
    end

    test "renders the history detail view", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/history")
      assert html =~ ~s(data-detail-view="history")
      assert html =~ "Conversation History"
    end

    test "history sub-nav lists History and Trash sections", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/history")
      assert html =~ ~s(data-detail-section="history")
      assert html =~ ~s(data-detail-section="trash")
    end

    test "lists user's conversations", %{conn: conn, user: user} do
      {:ok, _} = Magus.Chat.create_conversation(%{title: "Findable one"}, actor: user)

      {:ok, view, _html} = live(conn, "/history")
      assert render(view) =~ "Findable one"
    end

    test "orders conversations by most recent message activity, not updated_at",
         %{conn: conn, user: user} do
      # Bravo has a message -> recent last_message_at.
      {:ok, bravo} = Magus.Chat.create_conversation(%{title: "Bravo conversation"}, actor: user)
      generate(message(actor: user, conversation_id: bravo.id, text: "hi"))

      # Alpha is created last -> newest updated_at, but has no messages (nil last_message_at).
      {:ok, _alpha} = Magus.Chat.create_conversation(%{title: "Alpha conversation"}, actor: user)

      {:ok, view, _html} = live(conn, "/history")
      html = render(view)

      {bravo_pos, _} = :binary.match(html, "Bravo conversation")
      {alpha_pos, _} = :binary.match(html, "Alpha conversation")

      # Ordered by last_message_at desc_nils_last: Bravo (has a message) precedes
      # Alpha (none). Under the old updated_at sort, Alpha would come first.
      assert bravo_pos < alpha_pos
    end

    test "?tab=trash switches to the trash view", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/history?tab=trash")
      assert html =~ "Trash"
      assert html =~ "Trash is empty"
    end

    test "trash view shows soft-deleted conversations and restore action",
         %{conn: conn, user: user} do
      {:ok, conv} = Magus.Chat.create_conversation(%{title: "Going away"}, actor: user)
      Magus.Chat.soft_delete_conversation!(conv, actor: user)

      {:ok, view, _html} = live(conn, "/history?tab=trash")
      html = render(view)
      assert html =~ "Going away"
      assert html =~ ~s(phx-click="restore")
    end
  end

  describe "workspace scoping" do
    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      %{conn: log_in_user_with_workspace(conn, user, ws), user: user, workspace: ws}
    end

    test "history in workspace shows only that workspace's conversations",
         %{conn: conn, user: user, workspace: ws} do
      {:ok, _in_ws} =
        Magus.Chat.create_conversation(%{title: "In workspace", workspace_id: ws.id}, actor: user)

      {:ok, _personal} = Magus.Chat.create_conversation(%{title: "Personal one"}, actor: user)

      {:ok, view, _html} = live(conn, "/history")
      html = render(view)
      assert html =~ "In workspace"
      refute html =~ "Personal one"
    end

    test "personal history (no workspace) excludes workspace conversations" do
      # Fresh user not in any workspace, so the workbench mounts in personal mode.
      personal_user = generate(user())
      ensure_workspace_plan(personal_user)
      ws_for_user = generate(workspace(actor: personal_user))

      {:ok, _personal} =
        Magus.Chat.create_conversation(%{title: "Personal only"}, actor: personal_user)

      {:ok, _in_ws} =
        Magus.Chat.create_conversation(
          %{title: "Workspace only", workspace_id: ws_for_user.id},
          actor: personal_user
        )

      personal_conn = log_in_user(Phoenix.ConnTest.build_conn(), personal_user)
      {:ok, view, _html} = live(personal_conn, "/history")
      html = render(view)
      assert html =~ "Personal only"
      refute html =~ "Workspace only"
    end

    test "trash in workspace shows only that workspace's trashed conversations",
         %{conn: conn, user: user, workspace: ws} do
      {:ok, ws_conv} =
        Magus.Chat.create_conversation(%{title: "Deleted in ws", workspace_id: ws.id},
          actor: user
        )

      Magus.Chat.soft_delete_conversation!(ws_conv, actor: user)

      {:ok, personal_conv} =
        Magus.Chat.create_conversation(%{title: "Deleted personally"}, actor: user)

      Magus.Chat.soft_delete_conversation!(personal_conv, actor: user)

      {:ok, view, _html} = live(conn, "/history?tab=trash")
      html = render(view)
      assert html =~ "Deleted in ws"
      refute html =~ "Deleted personally"
    end

    test "empty_trash only wipes the active workspace's trashed conversations",
         %{conn: conn, user: user, workspace: ws} do
      {:ok, ws_conv} =
        Magus.Chat.create_conversation(%{title: "ws-trash", workspace_id: ws.id}, actor: user)

      Magus.Chat.soft_delete_conversation!(ws_conv, actor: user)

      {:ok, personal_conv} =
        Magus.Chat.create_conversation(%{title: "personal-trash"}, actor: user)

      Magus.Chat.soft_delete_conversation!(personal_conv, actor: user)

      {:ok, view, _html} = live(conn, "/history?tab=trash")
      child = find_live_child(view, "detail-history-trash-#{ws.id}")
      assert child, "expected the HistoryView child LV to be mounted"
      child |> element("button[phx-click=empty_trash]") |> render_click()

      # Workspace trash is wiped, personal trash survives.
      require Ash.Query

      remaining_ids =
        Magus.Chat.Conversation
        |> Ash.Query.for_read(:trashed, %{}, actor: user)
        |> Ash.read!(actor: user)
        |> Enum.map(& &1.id)

      refute ws_conv.id in remaining_ids
      assert personal_conv.id in remaining_ids
    end
  end
end
