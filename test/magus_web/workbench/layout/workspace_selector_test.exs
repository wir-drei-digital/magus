defmodule MagusWeb.Workbench.Layout.WorkspaceSelectorTest do
  use MagusWeb.LiveViewCase, async: false
  import Magus.Generators

  alias MagusWeb.Workbench.Layout.WorkspaceSelector

  test "renders the current workspace name when provided" do
    user = generate(user())
    ensure_workspace_plan(user)
    ws = generate(workspace(actor: user))

    assigns = %{
      id: "ws",
      current_user: user,
      current_workspace: ws,
      workspaces: [ws]
    }

    html = Phoenix.LiveViewTest.render_component(WorkspaceSelector, assigns)

    assert html =~ ws.name
    assert html =~ ~s(data-workspace-selector)
  end

  test "renders Personal when current_workspace is nil" do
    user = generate(user())

    assigns = %{
      id: "ws",
      current_user: user,
      current_workspace: nil,
      workspaces: []
    }

    html = Phoenix.LiveViewTest.render_component(WorkspaceSelector, assigns)

    assert html =~ "Personal"
  end

  test "includes a New workspace action" do
    user = generate(user())

    assigns = %{
      id: "ws",
      current_user: user,
      current_workspace: nil,
      workspaces: []
    }

    html = Phoenix.LiveViewTest.render_component(WorkspaceSelector, assigns)

    assert html =~ "New workspace"
    assert html =~ ~s(phx-click="open_create_workspace")
  end
end
