defmodule MagusWeb.Workbench.Tab.CompanionConversationTest do
  use MagusWeb.LiveViewCase, async: false
  import MagusWeb.LiveViewCase
  import Phoenix.LiveViewTest
  import Magus.Generators
  import MagusWeb.Workbench.TestHelpers

  test "ConversationView in companion role renders trimmed header with back button",
       %{conn: conn} do
    user = generate(user())
    {:ok, conv} = Magus.Chat.create_conversation(%{title: "Hello"}, actor: user)
    conn = log_in_user(conn, user)

    {:ok, _view, html} =
      live_isolated(conn, MagusWeb.Workbench.Resources.ConversationView,
        session: %{
          "conversation_id" => conv.id,
          "user_id" => user.id,
          "tab_id" => "tab-1",
          "role" => "companion"
        }
      )

    assert html =~ ~s(data-companion-back)
    assert html =~ "Hello"
  end

  test "ConversationView defaults to primary role and does NOT render back button",
       %{conn: conn} do
    user = generate(user())
    {:ok, conv} = Magus.Chat.create_conversation(%{title: "Hello"}, actor: user)
    conn = log_in_user(conn, user)

    {:ok, _view, html} =
      live_isolated(conn, MagusWeb.Workbench.Resources.ConversationView,
        session: %{
          "conversation_id" => conv.id,
          "user_id" => user.id,
          "tab_id" => "tab-1"
        }
      )

    refute html =~ ~s(data-companion-back)
    assert html =~ "Hello"
  end

  test "TabContainer renders ConversationView in companion role for type=conversation",
       %{conn: conn} do
    user = generate(user())
    ensure_workspace_plan(user)
    ws = generate(workspace(actor: user))

    {:ok, primary_conv} =
      Magus.Chat.create_conversation(%{title: "Primary", workspace_id: ws.id}, actor: user)

    {:ok, comp_conv} =
      Magus.Chat.create_conversation(
        %{title: "Companion chat", workspace_id: ws.id},
        actor: user
      )

    conn = log_in_user_with_workspace(conn, user, ws)
    {:ok, view, _html} = live(conn, ~p"/chat/#{primary_conv.id}")

    {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
    tab_id = session.active_tab_id

    MagusWeb.Workbench.Signals.broadcast_open_companion(tab_id, %{
      "type" => "conversation",
      "id" => comp_conv.id
    })

    :ok = poll_until(fn -> render(view) =~ "Companion chat" end)

    assert render(view) =~ ~s(data-companion-back)
  end
end
