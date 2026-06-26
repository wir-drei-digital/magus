defmodule MagusWeb.Workbench.ConversationViewCompactionTest do
  use MagusWeb.LiveViewCase, async: false
  import MagusWeb.LiveViewCase
  import Phoenix.LiveViewTest
  import Magus.Generators

  setup %{conn: conn} do
    user = generate(user())
    {:ok, conv} = Magus.Chat.create_conversation(%{title: "c"}, actor: user)
    %{conn: log_in_user(conn, user), user: user, conv: conv}
  end

  defp inner_view(view, conv, user) do
    {:ok, session} = Magus.Workbench.get_tab_session(nil, actor: user)
    tab_id = session.active_tab_id

    view
    |> find_live_child("tab-#{tab_id}")
    |> find_live_child("conversation-#{conv.id}")
  end

  test "compaction indicator shows while a compaction is running", %{
    conn: conn,
    user: user,
    conv: conv
  } do
    {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

    inner = inner_view(view, conv, user)
    refute has_element?(inner, "[data-role=agent-compacting]")

    # Drive the window into :running via the real action path.
    {:ok, cw} = Magus.Chat.get_or_create_context_window(conv.id, actor: user)
    {:ok, _} = cw |> Ash.Changeset.for_update(:mark_compacting, %{}) |> Ash.update()

    # The ContextPlugin pushes a context.updated broadcast after a status change;
    # replay it here so the LiveView refreshes its context_window assign.
    Magus.Agents.Signals.context_updated(conv.id, %{})

    inner = inner_view(view, conv, user)
    assert has_element?(inner, "[data-role=agent-compacting]")
  end
end
