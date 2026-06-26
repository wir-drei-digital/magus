defmodule MagusWeb.Workbench.Mobile.DrawerTest do
  use MagusWeb.LiveViewCase, async: false
  import MagusWeb.LiveViewCase
  import Phoenix.LiveViewTest
  import Magus.Generators

  describe "drawer renders inside WorkbenchLive on mobile" do
    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      conn = log_in_user_with_workspace(conn, user, ws)
      %{conn: conn, user: user, workspace: ws}
    end

    test "drawer DOM is present (closed by default)", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/chat")

      assert html =~ ~s(data-mobile-drawer)
      assert html =~ ~s(data-drawer-open="false")
      # Closed drawer renders only the outer shell — no inner markers
      refute html =~ ~s(data-mode-picker-layout="horizontal")
    end

    test "drawer carries dialog a11y attributes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      closed = render(view)
      assert closed =~ ~s(role="dialog")
      assert closed =~ ~s(aria-modal="true")
      assert closed =~ ~s(aria-hidden="true")

      render_hook(view, "toggle_drawer", %{})
      open = render(view)
      assert open =~ ~s(aria-hidden="false")
    end

    test "drawer renders inner sections when open", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")
      render_hook(view, "toggle_drawer", %{})
      html = render(view)

      assert html =~ ~s(data-drawer-open="true")
      # Mode picker renders horizontally inside the drawer when open
      assert html =~ ~s(data-mode-picker-layout="horizontal")
      # Footer marker
      assert html =~ ~s(data-drawer-footer)
    end

    test "drawer toggles open via hamburger event", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      render_hook(view, "toggle_drawer", %{})
      html = render(view)
      assert html =~ ~s(data-drawer-open="true")
      assert html =~ ~s(data-mobile-drawer-backdrop)
    end

    test "drawer closes when a conversation is picked from inside it",
         %{conn: conn, user: user, workspace: ws} do
      {:ok, conv} =
        Magus.Chat.create_conversation(%{title: "Inside drawer", workspace_id: ws.id},
          actor: user
        )

      {:ok, view, _html} = live(conn, ~p"/chat")
      render_hook(view, "toggle_drawer", %{})
      assert render(view) =~ ~s(data-drawer-open="true")

      view
      |> element(
        ~s([data-mobile-drawer] button[phx-value-id="#{conv.id}"][phx-value-type="conversation"])
      )
      |> render_click()

      assert render(view) =~ ~s(data-drawer-open="false")
    end
  end
end
