defmodule MagusWeb.Workbench.FileBrowserIntegrationTest do
  @moduledoc """
  End-to-end integration tests for the file browser inside WorkbenchLive.
  Covers cross-mode navigation and sidebar/active-tab synchronization.
  """
  use MagusWeb.LiveViewCase, async: false

  import MagusWeb.LiveViewCase
  import Magus.Generators
  import Phoenix.LiveViewTest

  describe "mode-icon navigation" do
    test "clicking the files mode icon from chat mode shows the Files sidebar",
         %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/chat")
      # Default mode is chat — files sidebar is not yet rendered.
      assert html =~ ~s(data-mode="chat")
      refute html =~ "Filters"

      view |> element(~s([data-mode-icon="files"])) |> render_click()

      html = render(view)
      assert html =~ ~s(data-mode="files")
      # FilesModeNav rendered inside the sidebar.
      assert html =~ "My Files"
      assert html =~ "Storage"
    end
  end

  describe "active tab → sidebar pill labels" do
    @describetag :skip
    # Filters are hidden behind `:if={false}` in files_mode_nav.ex's render
    # ("chore: hide file filter for now"). Re-enable these tests when the
    # filter UI comes back.

    test "navigating to /files?type=image makes the sidebar Type pill label include Image",
         %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      conn = log_in_user_with_workspace(conn, user, ws)

      {:ok, view, _html} = live(conn, ~p"/files?type=image")

      html = render(view)

      # The sidebar reads the active tab's filters and rebuilds the pill
      # label, so we should see "Type: Image" instead of just "Type".
      assert html =~ "Type: Image"
    end

    test "navigating to /files (no filters) shows the bare Type pill label",
         %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      conn = log_in_user_with_workspace(conn, user, ws)

      {:ok, view, _html} = live(conn, ~p"/files")

      html = render(view)
      # No active filter, so the pill label is just "Type".
      assert html =~ ~r{>\s*Type\s*<}
      refute html =~ "Type: Image"
    end
  end
end
