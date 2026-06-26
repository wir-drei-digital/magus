defmodule MagusWeb.Workbench.Tab.TabContainerSpreadsheetTest do
  @moduledoc """
  Asserts that a tab whose companion has type "spreadsheet" routes to
  SpreadsheetCompanion via TabContainer's render_companion/1 dispatch.
  """
  use MagusWeb.LiveViewCase, async: false

  import MagusWeb.LiveViewCase
  import Magus.Generators
  import MagusWeb.Workbench.TestHelpers

  @ai_agent %Magus.Agents.Support.AiAgent{}

  test "TabContainer routes companion type=spreadsheet to SpreadsheetCompanion",
       %{conn: conn} do
    user = generate(user())
    ensure_workspace_plan(user)
    ws = generate(workspace(actor: user))

    binary =
      File.read!(Path.join(__DIR__, "../../../support/fixtures/sample.xlsx"))

    {:ok, file} =
      Magus.Files.create_file_from_content(
        %{
          name: "report.xlsx",
          type: :document,
          mime_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
          user_id: user.id,
          content: binary
        },
        actor: @ai_agent
      )

    {:ok, primary_conv} =
      Magus.Chat.create_conversation(
        %{title: "Primary", workspace_id: ws.id},
        actor: user
      )

    conn = log_in_user_with_workspace(conn, user, ws)
    {:ok, view, _html} = Phoenix.LiveViewTest.live(conn, ~p"/chat/#{primary_conv.id}")

    {:ok, session} = Magus.Workbench.get_tab_session(ws.id, actor: user)
    tab_id = session.active_tab_id

    MagusWeb.Workbench.Signals.broadcast_open_companion(tab_id, %{
      "type" => "spreadsheet",
      "id" => file.id,
      "name" => file.name
    })

    :ok =
      poll_until(fn ->
        Phoenix.LiveViewTest.render(view) =~ "data-spreadsheet-companion"
      end)

    assert Phoenix.LiveViewTest.render(view) =~ "report.xlsx"
  end
end
