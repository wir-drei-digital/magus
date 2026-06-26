defmodule MagusWeb.Workbench.Detail.WorkspaceSettingsViewTest do
  use MagusWeb.LiveViewCase, async: false

  import Phoenix.LiveViewTest
  import MagusWeb.LiveViewCase
  import Magus.Generators

  describe "GET /workspaces/:slug" do
    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      # Use log_in_user (not log_in_user_with_workspace) — WorkbenchLive mounts
      # without a current workspace context; the workspace detail views load
      # the workspace by slug independently.
      conn = log_in_user(conn, user)
      %{conn: conn, user: user, workspace: ws}
    end

    test "renders workspace settings", %{conn: conn, workspace: ws} do
      {:ok, _view, html} = live(conn, "/workspaces/#{ws.slug}")
      assert html =~ ~s(data-detail-view="workspace_settings")
    end

    test "renders workspace members at /members", %{conn: conn, workspace: ws} do
      {:ok, _view, html} = live(conn, "/workspaces/#{ws.slug}/members")
      assert html =~ ~s(data-detail-view="workspace_members")
    end

    test "workspace selector exposes settings link when in a workspace", %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      conn = log_in_user_with_workspace(conn, user, ws)
      {:ok, _view, html} = live(conn, ~p"/chat")
      assert html =~ ~s(data-workspace-settings)
    end
  end

  # Detail navigation lives entirely in the workbench DetailNav pane. The
  # body of each detail view (settings, members, usage) must not render its
  # own duplicate pill navigation.
  describe "no duplicate nav in workbench detail body" do
    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      conn = log_in_user(conn, user)
      %{conn: conn, user: user, workspace: ws}
    end

    test "workspace settings detail nav has all three sections", %{conn: conn, workspace: ws} do
      {:ok, _view, html} = live(conn, "/workspaces/#{ws.slug}")

      assert length(Regex.scan(~r/data-detail-section="settings"/, html)) == 1
      assert length(Regex.scan(~r/data-detail-section="members"/, html)) == 1
      assert length(Regex.scan(~r/data-detail-section="usage"/, html)) == 1
    end

    test "workspace settings body does not render its own tab pills",
         %{conn: conn, workspace: ws} do
      {:ok, _view, html} = live(conn, "/workspaces/#{ws.slug}")

      refute html =~ "phx-click=\"set_tab\""
      refute html =~ "?tab=usage"
      refute html =~ "?tab=billing"
    end

    test "workspace members body does not render its own tab pills",
         %{conn: conn, workspace: ws} do
      {:ok, _view, html} = live(conn, "/workspaces/#{ws.slug}/members")

      refute html =~ "phx-click=\"set_tab\""
      refute html =~ "?tab=usage"
      refute html =~ "?tab=billing"
    end
  end

  describe "delete workspace" do
    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      conn = log_in_user(conn, user)
      %{conn: conn, user: user, workspace: ws}
    end

    test "renders danger zone with delete button", %{conn: conn, workspace: ws} do
      {:ok, _view, html} = live(conn, "/workspaces/#{ws.slug}")
      assert html =~ "Danger Zone"
      assert html =~ "Delete Workspace"
    end

    test "opens confirmation modal on click", %{conn: conn, workspace: ws} do
      {:ok, view, _html} = live(conn, "/workspaces/#{ws.slug}")
      child = find_live_child(view, "detail-workspace-settings-#{ws.slug}")

      html =
        child
        |> element(~s(button[phx-click="open_delete_modal"]))
        |> render_click()

      assert html =~ "Delete workspace permanently"
      assert html =~ "This action cannot be undone"
    end

    test "submit button disabled until typed name matches", %{conn: conn, workspace: ws} do
      {:ok, view, _html} = live(conn, "/workspaces/#{ws.slug}")
      child = find_live_child(view, "detail-workspace-settings-#{ws.slug}")

      child
      |> element(~s(button[phx-click="open_delete_modal"]))
      |> render_click()

      # Disabled when name doesn't match
      html =
        child
        |> form("#delete-workspace-form", %{"confirm_name" => "wrong"})
        |> render_change()

      assert html =~ ~s(<button type="submit" disabled="" class="btn btn-error">)

      # Enabled when name matches
      html =
        child
        |> form("#delete-workspace-form", %{"confirm_name" => ws.name})
        |> render_change()

      refute html =~ ~s(<button type="submit" disabled)
    end

    test "hard-deletes workspace on confirm", %{conn: conn, workspace: ws} do
      {:ok, view, _html} = live(conn, "/workspaces/#{ws.slug}")
      child = find_live_child(view, "detail-workspace-settings-#{ws.slug}")

      child
      |> element(~s(button[phx-click="open_delete_modal"]))
      |> render_click()

      render_hook(child, "delete_workspace", %{"confirm_name" => ws.name})

      assert {:error, _} = Ash.get(Magus.Workspaces.Workspace, ws.id, authorize?: false)
    end

    test "ignores submit when typed name does not match", %{conn: conn, workspace: ws} do
      {:ok, view, _html} = live(conn, "/workspaces/#{ws.slug}")
      child = find_live_child(view, "detail-workspace-settings-#{ws.slug}")

      child
      |> element(~s(button[phx-click="open_delete_modal"]))
      |> render_click()

      child
      |> form("#delete-workspace-form", %{"confirm_name" => "nope"})
      |> render_submit()

      assert {:ok, _} = Ash.get(Magus.Workspaces.Workspace, ws.id, authorize?: false)
    end

    test "non-admin member cannot reach delete flow", %{conn: %{} = conn, workspace: ws} do
      # Reset conn auth and log in as a non-admin member of the workspace.
      member_user = generate(user())

      Magus.Workspaces.WorkspaceMember
      |> Ash.Changeset.for_create(:create_member, %{
        workspace_id: ws.id,
        user_id: member_user.id,
        invite_email: member_user.email
      })
      |> Ash.create!(authorize?: false)

      conn =
        conn
        |> Phoenix.ConnTest.recycle()
        |> log_in_user(member_user)

      # The settings live view redirects non-admins on mount.
      assert {:error, {:live_redirect, %{to: "/chat"}}} =
               live(conn, "/workspaces/#{ws.slug}")
    end

    test "cancel closes modal", %{conn: conn, workspace: ws} do
      {:ok, view, _html} = live(conn, "/workspaces/#{ws.slug}")
      child = find_live_child(view, "detail-workspace-settings-#{ws.slug}")

      child
      |> element(~s(button[phx-click="open_delete_modal"]))
      |> render_click()

      html =
        child
        |> element(~s(button[phx-click="close_delete_modal"]))
        |> render_click()

      refute html =~ "Delete workspace permanently"
    end
  end

  describe "GET /workspaces/:slug/usage" do
    setup %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      conn = log_in_user(conn, user)
      %{conn: conn, user: user, workspace: ws}
    end

    test "renders workspace usage as its own detail view", %{conn: conn, workspace: ws} do
      {:ok, view, html} = live(conn, "/workspaces/#{ws.slug}/usage")
      assert html =~ ~s(data-detail-view="workspace_usage")

      child = find_live_child(view, "detail-workspace-usage-#{ws.slug}")
      assert child, "Expected to find WorkspaceUsageView child LV"
      assert render(child) =~ "Workspace Usage"
      assert render(child) =~ "Billable tokens today"
    end
  end
end
