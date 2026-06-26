defmodule MagusWeb.Workbench.Resources.ConversationViewHeaderTest do
  use MagusWeb.LiveViewCase, async: false
  import MagusWeb.LiveViewCase
  import Phoenix.LiveViewTest
  import Magus.Generators

  setup %{conn: conn} do
    user = generate(user())
    {:ok, conv} = Magus.Chat.create_conversation(%{title: "Hello world"}, actor: user)
    %{conn: log_in_user(conn, user), user: user, conv: conv}
  end

  test "renders title and favorite/share action buttons", %{conn: conn, conv: conv} do
    {:ok, view, html} = live(conn, ~p"/chat/#{conv.id}")
    assert html =~ "Hello world"
    assert has_element?(view, "[data-conversation-favorite]")
    assert has_element?(view, "[data-conversation-share]")
  end

  test "favorite toggle persists", %{conn: conn, user: user, conv: conv} do
    {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

    {:ok, session} = Magus.Workbench.get_tab_session(nil, actor: user)
    tab_id = session.active_tab_id

    inner =
      view
      |> find_live_child("tab-#{tab_id}")
      |> find_live_child("conversation-#{conv.id}")

    inner |> element("[data-conversation-favorite]") |> render_click()
    assert {:ok, _} = Magus.Chat.get_conversation_favorite(conv.id, actor: user)
  end

  test "favorite toggle broadcasts to workbench user topic", %{
    conn: conn,
    user: user,
    conv: conv
  } do
    Phoenix.PubSub.subscribe(
      Magus.PubSub,
      MagusWeb.Workbench.Signals.workbench_user_topic(user.id)
    )

    {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

    {:ok, session} = Magus.Workbench.get_tab_session(nil, actor: user)
    tab_id = session.active_tab_id

    inner =
      view
      |> find_live_child("tab-#{tab_id}")
      |> find_live_child("conversation-#{conv.id}")

    inner |> element("[data-conversation-favorite]") |> render_click()

    assert_receive {:workbench_user, :conversation_favorites_changed}, 500
  end

  test "favorite from header surfaces a Favorites section in the chat-mode nav",
       %{conn: conn, user: user, conv: conv} do
    {:ok, view, html} = live(conn, ~p"/chat/#{conv.id}")
    refute html =~ "Favorites ("

    {:ok, session} = Magus.Workbench.get_tab_session(nil, actor: user)
    tab_id = session.active_tab_id

    inner =
      view
      |> find_live_child("tab-#{tab_id}")
      |> find_live_child("conversation-#{conv.id}")

    inner |> element("[data-conversation-favorite]") |> render_click()

    # Allow the PubSub round-trip + send_update from WorkbenchLive to settle.
    nav_html = render(view)
    assert nav_html =~ "Favorites (1)"
    assert nav_html =~ conv.title
  end

  test "share button opens the share modal", %{conn: conn, user: user, conv: conv} do
    {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

    {:ok, session} = Magus.Workbench.get_tab_session(nil, actor: user)
    tab_id = session.active_tab_id

    inner =
      view
      |> find_live_child("tab-#{tab_id}")
      |> find_live_child("conversation-#{conv.id}")

    refute render(inner) =~ "modal-open"

    inner |> element("[data-conversation-share]") |> render_click()

    rendered = render(inner)
    assert rendered =~ "modal-open"
    assert rendered =~ "Share Conversation"
  end

  test "shows Multiplayer badge when conversation is_multiplayer", %{conn: conn, user: user} do
    {:ok, conv} = Magus.Chat.create_conversation(%{title: "MP"}, actor: user)
    {:ok, _conv} = Magus.Chat.enable_multiplayer(conv, actor: user)

    {:ok, _view, html} = live(log_in_user(conn, user), ~p"/chat/#{conv.id}")
    assert html =~ "Multiplayer"
  end

  test "save_title persists the new title and keeps loaded relationships intact",
       %{conn: conn, user: user, conv: conv} do
    {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

    {:ok, session} = Magus.Workbench.get_tab_session(nil, actor: user)
    tab_id = session.active_tab_id

    inner =
      view
      |> find_live_child("tab-#{tab_id}")
      |> find_live_child("conversation-#{conv.id}")

    inner
    |> element("h2[phx-click='start_edit_title']")
    |> render_click()

    inner
    |> form("form[phx-submit='save_title']", %{"title" => "New title"})
    |> render_submit()

    # Title was actually persisted, not just optimistically swapped in the LV.
    reloaded =
      Magus.Chat.get_conversation!(conv.id,
        actor: user,
        load: [:message_count, :last_message_at]
      )

    assert reloaded.title == "New title"
    # Loaded fields must remain loaded after the in-memory assign update —
    # if the LV clobbers the assign with a fresh struct, downstream renders
    # that read these would crash on %Ash.NotLoaded{}.
    refute match?(%Ash.NotLoaded{}, reloaded.message_count)
  end
end
