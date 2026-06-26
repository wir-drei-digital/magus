defmodule MagusWeb.Workbench.Tab.RightRailTest do
  use MagusWeb.LiveViewCase, async: false
  import MagusWeb.LiveViewCase
  import Phoenix.LiveViewTest
  import Magus.Generators

  alias Magus.Brain

  setup %{conn: conn} do
    user = generate(user())
    {:ok, conv} = Magus.Chat.create_conversation(%{title: "C"}, actor: user)
    %{conn: log_in_user(conn, user), user: user, conv: conv}
  end

  defp tab_view(view, user) do
    {:ok, session} = Magus.Workbench.get_tab_session(nil, actor: user)
    find_live_child(view, "tab-#{session.active_tab_id}")
  end

  defp conversation_view(view, user, conv) do
    view
    |> tab_view(user)
    |> find_live_child("conversation-#{conv.id}")
  end

  defp open_rail(conversation_view) do
    conversation_view |> element("[data-right-rail-trigger]") |> render_click()
    conversation_view
  end

  test "rail trigger mounts on chat tabs", %{conn: conn, conv: conv} do
    {:ok, view, _} = live(conn, ~p"/chat/#{conv.id}")
    assert has_element?(view, "[data-right-rail-trigger]")
  end

  test "rail trigger does NOT mount on brain page tabs", %{conn: conn, user: user} do
    {:ok, brain} = Brain.create_brain(%{title: "B"}, actor: user)
    {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)
    {:ok, view, _} = live(conn, ~p"/brain/#{page.id}")
    refute has_element?(view, "[data-right-rail-trigger]")
  end

  test "trigger opens and closes panel; icon swaps active panel",
       %{conn: conn, user: user, conv: conv} do
    {:ok, view, _} = live(conn, ~p"/chat/#{conv.id}")
    conversation_view = conversation_view(view, user, conv)

    conversation_view
    |> open_rail()

    assert has_element?(conversation_view, "[data-right-rail-panel='prompts']")

    conversation_view |> element("[data-right-rail-trigger]") |> render_click()
    refute has_element?(conversation_view, "[data-right-rail-panel='prompts']")

    conversation_view |> element("[data-right-rail-trigger]") |> render_click()
    conversation_view |> element("[data-rail-icon='brains']") |> render_click()

    assert has_element?(conversation_view, "[data-right-rail-panel='brains']")
    refute has_element?(conversation_view, "[data-right-rail-panel='prompts']")
  end

  for {panel, marker} <- [
        {"prompts", "Prompts"},
        {"brains", "Brains"},
        {"drafts", "Drafts"},
        {"files", "Files"},
        {"settings", "Settings"}
      ] do
    test "#{panel} panel renders content from ported legacy component",
         %{conn: conn, user: user, conv: conv} do
      {:ok, view, _} = live(conn, ~p"/chat/#{conv.id}")
      conversation_view = view |> conversation_view(user, conv) |> open_rail()

      if unquote(panel) != "prompts" do
        conversation_view |> element("[data-rail-icon='#{unquote(panel)}']") |> render_click()
      end

      assert render(conversation_view) =~ unquote(marker)
    end
  end

  describe "jobs visibility" do
    test "jobs icon hidden when conversation has no jobs",
         %{conn: conn, user: user, conv: conv} do
      {:ok, view, _} = live(conn, ~p"/chat/#{conv.id}")
      conversation_view = view |> conversation_view(user, conv) |> open_rail()
      refute has_element?(conversation_view, "[data-rail-icon='jobs']")
    end

    test "jobs icon visible when conversation has an active job",
         %{conn: conn, user: user, conv: conv} do
      {:ok, _} =
        Magus.Chat.add_conversation_owner(conv.id, user.id, actor: user, authorize?: false)

      {:ok, _job} =
        Magus.Workflows.create_job(
          conv.id,
          %{
            name: "Backup",
            trigger_prompt: "back it up",
            schedule_type: :cron,
            cron_expression: "0 * * * *",
            ends_at: DateTime.add(DateTime.utc_now(), 7, :day)
          },
          actor: user
        )

      {:ok, view, _} = live(conn, ~p"/chat/#{conv.id}")
      conversation_view = view |> conversation_view(user, conv) |> open_rail()
      assert has_element?(conversation_view, "[data-rail-icon='jobs']")
    end

    test "jobs panel lists active jobs by name",
         %{conn: conn, user: user, conv: conv} do
      {:ok, _} =
        Magus.Chat.add_conversation_owner(conv.id, user.id, actor: user, authorize?: false)

      {:ok, _job} =
        Magus.Workflows.create_job(
          conv.id,
          %{
            name: "Backup",
            trigger_prompt: "back it up",
            schedule_type: :cron,
            cron_expression: "0 * * * *",
            ends_at: DateTime.add(DateTime.utc_now(), 7, :day)
          },
          actor: user
        )

      {:ok, view, _} = live(conn, ~p"/chat/#{conv.id}")
      conversation_view = view |> conversation_view(user, conv) |> open_rail()
      conversation_view |> element("[data-rail-icon='jobs']") |> render_click()
      assert render(conversation_view) =~ "Backup"
    end
  end
end
