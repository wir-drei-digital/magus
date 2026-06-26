defmodule MagusWeb.Workbench.Mobile.CompanionTakeoverTest do
  use MagusWeb.LiveViewCase, async: false
  import MagusWeb.LiveViewCase
  import Phoenix.LiveViewTest
  import Magus.Generators
  import MagusWeb.Workbench.TestHelpers

  alias MagusWeb.Workbench.Signals

  setup %{conn: conn} do
    user = generate(user())
    ensure_workspace_plan(user)
    ws = generate(workspace(actor: user))

    {:ok, conv} =
      Magus.Chat.create_conversation(%{title: "Conv with companion", workspace_id: ws.id},
        actor: user
      )

    conn = log_in_user_with_workspace(conn, user, ws)
    %{conn: conn, user: user, workspace: ws, conversation: conv}
  end

  test "TabContainer with no companion still has a display rule (regression: chat input must be reachable)",
       %{conn: conn, conversation: conv} do
    {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

    html = render(view)

    # The tab-container element MUST set a display rule (grid or flex) on its
    # outer div so the inner section gets a constrained height. Without one,
    # the conversation view's `h-full` collapses to zero, the messages area
    # cannot scroll, and the chat input flows below the visible area.
    # Match the <div ...> tag that contains data-tab-container and pull its class.
    # Class can appear either before or after the data-* attribute in the tag.
    container_classes =
      Regex.scan(~r/<div[^>]*data-tab-container[^>]*>/, html)
      |> List.first()
      |> case do
        nil -> ""
        [tag] -> Regex.run(~r/class="([^"]+)"/, tag) |> Enum.at(1, "")
      end

    assert container_classes =~ "h-full",
           "tab-container missing h-full: #{inspect(container_classes)}"

    assert container_classes =~ ~r/\b(grid|flex)\b/,
           "tab-container missing display rule (grid or flex): #{inspect(container_classes)}"
  end

  test "TabContainer marks the companion-takeover branch when a companion is set",
       %{conn: conn, user: user, workspace: ws, conversation: conv} do
    {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

    {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
    tab_id = session.active_tab_id

    Signals.broadcast_open_companion(tab_id, %{"type" => "tasks", "id" => conv.id})

    :ok = poll_until(fn -> render(view) =~ ~s(data-mobile-companion-active="true") end)
    # Mobile workbench header collapses in companion variant; the companion
    # view's own header carries the back affordance.
    refute render(view) =~ ~s(data-mobile-header-variant="companion")
  end

  test "the back arrow dispatches close_companion which clears the companion",
       %{conn: conn, user: user, workspace: ws, conversation: conv} do
    {:ok, view, _html} = live(conn, ~p"/chat/#{conv.id}")

    {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
    tab_id = session.active_tab_id

    Signals.broadcast_open_companion(tab_id, %{"type" => "tasks", "id" => conv.id})
    :ok = poll_until(fn -> render(view) =~ ~s(data-mobile-companion-active="true") end)

    render_hook(view, "close_companion", %{})

    :ok =
      poll_until(fn ->
        {:ok, s} = Magus.Workbench.get_tab_session(ws.id, actor: user)
        tab = Enum.find(s.tabs, fn t -> t["id"] == tab_id end)
        tab && is_nil(tab["companion"])
      end)
  end
end
