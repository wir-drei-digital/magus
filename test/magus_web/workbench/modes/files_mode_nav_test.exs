defmodule MagusWeb.Workbench.Modes.FilesModeNavTest do
  @moduledoc """
  Tests for the Files mode sidebar (entry points + filter pills).
  Drives the WorkbenchLive at /chat and switches into Files mode.
  """
  use MagusWeb.LiveViewCase, async: false

  import MagusWeb.LiveViewCase
  import Magus.Generators
  import Phoenix.LiveViewTest

  describe "entry points" do
    test "personal mode hides 'Shared with me'", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/chat")
      view |> element(~s([data-mode-icon="files"])) |> render_click()

      html = render(view)
      assert html =~ "My Files"
      assert html =~ "Recent"
      assert html =~ "Trash"
      refute html =~ "Shared with me"
    end

    test "workspace mode shows 'Shared with me'", %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      conn = log_in_user_with_workspace(conn, user, ws)

      {:ok, view, _html} = live(conn, ~p"/chat")
      view |> element(~s([data-mode-icon="files"])) |> render_click()

      html = render(view)
      assert html =~ "My Files"
      assert html =~ "Shared with me"
    end
  end

  describe "filter pills" do
    @describetag :skip
    # Filters are hidden behind `:if={false}` in files_mode_nav.ex's render
    # ("chore: hide file filter for now"). Re-enable these tests when the
    # filter UI comes back.

    test "clicking a pill choice broadcasts an override on the workbench user topic",
         %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)

      Phoenix.PubSub.subscribe(
        Magus.PubSub,
        MagusWeb.Workbench.Signals.workbench_user_topic(user.id)
      )

      {:ok, view, _html} = live(conn, ~p"/chat")
      view |> element(~s([data-mode-icon="files"])) |> render_click()

      # Open the Type pill, then click the Image choice. The component
      # broadcasts the override to the user topic; WorkbenchLive listens
      # and `push_patch`es the URL with the new param.
      view
      |> element(~s(button[phx-click="open_pill"][phx-value-key="type"]))
      |> render_click()

      view
      |> element(
        ~s(button[phx-click="set_pill_value"][phx-value-key="type"][phx-value-value="image"])
      )
      |> render_click()

      assert_receive {:file_browser_patch_from_sidebar, %{"type" => "image"}}, 500
    end
  end
end
