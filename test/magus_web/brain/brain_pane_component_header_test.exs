defmodule MagusWeb.Brain.BrainPaneComponentHeaderTest do
  use MagusWeb.LiveViewCase, async: false
  import MagusWeb.LiveViewCase
  import Phoenix.LiveViewTest
  import Magus.Generators
  import MagusWeb.Workbench.TestHelpers

  alias Magus.Brain

  setup %{conn: conn} do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "Notes"}, actor: user)
    {:ok, page} = Brain.create_page(brain.id, %{title: "My page"}, actor: user)

    %{conn: log_in_user(conn, user), user: user, brain: brain, page: page}
  end

  test "header renders title, last-changed line, and Open chat button",
       %{conn: conn, page: page} do
    {:ok, _view, html} = live(conn, ~p"/brain/#{page.id}")

    assert html =~ "My page"
    assert html =~ "Updated"
    assert html =~ ~s(data-brain-open-chat)
  end

  test "Open chat finds-or-creates a companion conversation and opens it",
       %{conn: conn, user: user, page: page} do
    {:ok, view, _html} = live(conn, ~p"/brain/#{page.id}")

    # Reach into the nested BrainPageView LV. Two live_render levels:
    # WorkbenchLive -> TabContainer -> BrainPageView.
    {:ok, session} = Magus.Workbench.get_tab_session(nil, actor: user)
    tab_id = session.active_tab_id

    inner =
      view
      |> find_live_child("tab-#{tab_id}")
      |> find_live_child("brain-page-#{page.id}")

    inner
    |> element("button[data-brain-open-chat]")
    |> render_click()

    # Companion conversations are filtered out of my_conversations (Bundle C),
    # so look up via the companion link directly.
    :ok =
      poll_until(fn ->
        match?({:ok, _}, Magus.Chat.get_companion_by_resource(:brain_page, page.id, actor: user))
      end)

    :ok = poll_until(fn -> render(view) =~ ~s(data-companion-back) end)
  end
end
