defmodule MagusWeb.Workbench.Resources.Companions.ServiceCompanionTest do
  use MagusWeb.LiveViewCase, async: false
  import Magus.Generators

  alias MagusWeb.Workbench.Resources.Companions.ServiceCompanion

  test "mounts and renders service pane" do
    user = generate(user())
    ensure_workspace_plan(user)
    ws = generate(workspace(actor: user))

    {:ok, conv} =
      Magus.Chat.create_conversation(%{title: "Service test", workspace_id: ws.id}, actor: user)

    {:ok, _lv, html} =
      Phoenix.LiveViewTest.live_isolated(
        Phoenix.ConnTest.build_conn(),
        ServiceCompanion,
        session: %{
          "conversation_id" => conv.id,
          "user_id" => user.id,
          "tab_id" => "tab_abc"
        }
      )

    # Loose assertion — the service pane renders something even with no active service
    assert html =~ "service" or html =~ "Service" or html =~ "preview" or
             html =~ "data-service-companion"
  end
end
