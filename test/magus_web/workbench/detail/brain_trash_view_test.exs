defmodule MagusWeb.Workbench.Detail.BrainTrashViewTest do
  use MagusWeb.LiveViewCase, async: false

  import Phoenix.LiveViewTest
  import MagusWeb.LiveViewCase
  import Magus.Generators

  defp trash_page(user, brain, title \\ "Going away") do
    {:ok, page} = Magus.Brain.create_page(brain.id, %{title: title}, actor: user)
    {:ok, _} = Magus.Brain.soft_delete_page(page, actor: user)
    page
  end

  describe "GET /brain/trash" do
    setup %{conn: conn} do
      user = generate(user())
      %{conn: log_in_user(conn, user), user: user}
    end

    test "renders empty state when nothing is trashed", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/brain/trash")
      assert html =~ ~s(data-detail-view="brain-trash")
      assert html =~ "Trash is empty"
    end

    test "lists deletion roots only", %{conn: conn, user: user} do
      {:ok, brain} = Magus.Brain.create_brain(%{title: "B"}, actor: user)
      {:ok, root} = Magus.Brain.create_page(brain.id, %{title: "Top"}, actor: user)

      {:ok, _child} =
        Magus.Brain.create_page(brain.id, %{title: "Sub", parent_page_id: root.id}, actor: user)

      {:ok, _} = Magus.Brain.soft_delete_page(root, actor: user)

      {:ok, _view, html} = live(conn, "/brain/trash")
      assert html =~ "Top"
      refute html =~ ">Sub<"
    end

    test "restore brings the page back to the brain", %{conn: conn, user: user} do
      {:ok, brain} = Magus.Brain.create_brain(%{title: "B"}, actor: user)
      page = trash_page(user, brain)

      {:ok, view, _html} = live(conn, "/brain/trash")
      child = find_live_child(view, "detail-brain-trash-personal")
      render_click(child, "restore", %{"id" => page.id})

      assert {:ok, _} = Magus.Brain.get_page(page.id, actor: user)
      refute render(child) =~ "Going away"
    end

    test "permanently_delete hard-destroys", %{conn: conn, user: user} do
      {:ok, brain} = Magus.Brain.create_brain(%{title: "B"}, actor: user)
      page = trash_page(user, brain)

      {:ok, view, _html} = live(conn, "/brain/trash")
      child = find_live_child(view, "detail-brain-trash-personal")
      render_click(child, "permanently_delete", %{"id" => page.id})

      assert {:error, _} = Ash.get(Magus.Brain.Page, page.id, authorize?: false)
    end

    test "empty_trash wipes all rows in scope", %{conn: conn, user: user} do
      {:ok, brain} = Magus.Brain.create_brain(%{title: "B"}, actor: user)
      _ = trash_page(user, brain, "A")
      _ = trash_page(user, brain, "B")

      {:ok, view, _html} = live(conn, "/brain/trash")
      child = find_live_child(view, "detail-brain-trash-personal")
      render_click(child, "empty_trash", %{})

      {:ok, remaining} = Magus.Brain.list_trashed_pages(nil, actor: user)
      assert remaining == []
    end

    test "destructive buttons carry data-confirm attributes", %{conn: conn, user: user} do
      {:ok, brain} = Magus.Brain.create_brain(%{title: "B"}, actor: user)
      _ = trash_page(user, brain)

      {:ok, view, _html} = live(conn, "/brain/trash")
      child = find_live_child(view, "detail-brain-trash-personal")
      html = render(child)

      assert html =~ ~s(data-confirm="Permanently delete this page?)
      assert html =~ ~s(data-confirm="Permanently delete all pages in trash?)
    end

    test "child trashed under a trashed ancestor is invisible in the trash list",
         %{conn: conn, user: user} do
      {:ok, brain} = Magus.Brain.create_brain(%{title: "B"}, actor: user)
      {:ok, root} = Magus.Brain.create_page(brain.id, %{title: "RootName"}, actor: user)

      {:ok, child} =
        Magus.Brain.create_page(brain.id, %{title: "ChildName", parent_page_id: root.id},
          actor: user
        )

      # Trash child first, then root. Both are trashed; child is under
      # a trashed ancestor (root). The trash listing should only show root.
      {:ok, _} = Magus.Brain.soft_delete_page(child, actor: user)
      {:ok, _} = Magus.Brain.soft_delete_page(root, actor: user)

      {:ok, view, _html} = live(conn, "/brain/trash")
      child_lv = find_live_child(view, "detail-brain-trash-personal")
      html = render(child_lv)

      assert html =~ "RootName"
      refute html =~ "ChildName"
    end
  end

  describe "workspace scoping" do
    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      %{conn: log_in_user_with_workspace(conn, user, ws), user: user, workspace: ws}
    end

    test "shows only pages from brains in the active workspace",
         %{conn: conn, user: user, workspace: ws} do
      {:ok, ws_brain} =
        Magus.Brain.create_brain(%{title: "WS", workspace_id: ws.id}, actor: user)

      {:ok, personal_brain} = Magus.Brain.create_brain(%{title: "Pers"}, actor: user)

      {:ok, ws_page} =
        Magus.Brain.create_page(ws_brain.id, %{title: "WorkspaceOnlyPage"}, actor: user)

      {:ok, p_page} =
        Magus.Brain.create_page(personal_brain.id, %{title: "PersonalOnlyPage"}, actor: user)

      Magus.Brain.soft_delete_page!(ws_page, actor: user)
      Magus.Brain.soft_delete_page!(p_page, actor: user)

      {:ok, view, _html} = live(conn, "/brain/trash")
      child = find_live_child(view, "detail-brain-trash-#{ws.id}")
      child_html = render(child)

      assert child_html =~ "WorkspaceOnlyPage"
      refute child_html =~ "PersonalOnlyPage"
    end
  end
end
