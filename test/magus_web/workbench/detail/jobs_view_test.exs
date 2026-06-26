defmodule MagusWeb.Workbench.Detail.JobsViewTest do
  use MagusWeb.LiveViewCase, async: false

  import Phoenix.LiveViewTest
  import MagusWeb.LiveViewCase
  import Magus.Generators

  describe "GET /jobs" do
    setup %{conn: conn} do
      user = generate(user())
      %{conn: log_in_user(conn, user), user: user}
    end

    test "renders jobs list with no selection", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/jobs")
      assert html =~ ~s(data-detail-view="jobs")
      assert html =~ "Select a job to see details"
    end

    # I4: JobsView must render actual job entries when the user has jobs,
    # not just the empty state.
    test "renders job name in the list when user has jobs", %{conn: conn, user: user} do
      conv = generate(conversation(actor: user))

      generate(
        job(
          conversation_id: conv.id,
          user_id: user.id,
          name: "My Scheduled Task"
        )
      )

      {:ok, _view, html} = live(conn, "/jobs")

      assert html =~ "My Scheduled Task"
      refute html =~ "No scheduled jobs yet"
    end
  end
end
