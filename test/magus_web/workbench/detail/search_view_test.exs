defmodule MagusWeb.Workbench.Detail.SearchViewTest do
  use MagusWeb.LiveViewCase, async: false

  import Phoenix.LiveViewTest
  import MagusWeb.LiveViewCase
  import Magus.Generators
  import MagusWeb.Workbench.TestHelpers

  describe "GET /search" do
    setup %{conn: conn} do
      user = generate(user())
      %{conn: log_in_user(conn, user), user: user}
    end

    test "renders empty search at /search", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/search")
      assert html =~ ~s(data-detail-view="search")
    end

    test "renders search with query at /search?q=hello", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/search?q=hello")
      assert html =~ ~s(data-detail-view="search")
      assert html =~ "hello"
    end

    test "type filter sub-nav highlights active type", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/search?q=foo&type=conversations")
      assert html =~ ~s(data-detail-section="conversations")
    end
  end

  # C3 regression: SearchView must run the search immediately on mount when a
  # query is present, not wait for a subsequent user interaction.
  describe "C3: initial search on mount" do
    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      conn = log_in_user_with_workspace(conn, user, ws)
      %{conn: conn, user: user, workspace: ws}
    end

    test "renders search results (not empty state) when the query matches content",
         %{conn: conn, user: user, workspace: ws} do
      {:ok, _conv} =
        Magus.Chat.create_conversation(
          %{title: "Findable haystack", workspace_id: ws.id},
          actor: user
        )

      {:ok, view, _html} = live(conn, "/search?q=haystack")

      # The search runs asynchronously via send(self(), {:perform_search, ...}),
      # so poll until the result appears.
      :ok = poll_until(fn -> render(view) =~ "Findable haystack" end)

      refute render(view) =~ "Start typing"
    end

    test "does not trigger a search when query is too short (< 2 chars)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/search?q=x")
      # SearchView is a nested LiveView child; render the child to get its HTML.
      live_id = "detail-search-#{:erlang.phash2({"x", "all"})}"
      child = find_live_child(view, live_id)
      assert child, "Expected to find SearchView child LV (id: #{live_id})"
      # A 1-char query sets query in assigns but doesn't trigger a search.
      # The template shows "no results" (query != "" but results == [])
      # rather than the loading spinner, confirming no search was fired.
      refute render(child) =~ "Searching..."
    end
  end
end
