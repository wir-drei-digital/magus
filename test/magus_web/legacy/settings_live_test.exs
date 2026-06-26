defmodule MagusWeb.SettingsLive.MyDataTest do
  @moduledoc """
  LiveView tests for the My Data settings section: nav link, export/delete
  cards, and the delete-account confirmation modal (blocked + confirm states).
  """
  use MagusWeb.LiveViewCase, async: false

  import MagusWeb.LiveViewCase

  describe "GET /settings/data" do
    test "renders the My Data section with export and delete cards", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/settings/data")

      assert html =~ "My Data"
      assert html =~ "Export your data"
      assert html =~ "Delete your account"
      assert html =~ ~s(href="/settings/data/export")
    end

    test "sidebar contains a My Data nav link from the profile page", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ ~s(href="/settings/data")
    end
  end

  describe "delete-account modal" do
    test "blocked state when user is sole admin of a workspace", %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/settings/data")

      settings_view = find_live_child(view, "detail-settings-data")

      html =
        settings_view
        |> element("button[phx-click='open_delete_account_modal']")
        |> render_click()

      assert html =~ "only admin"
      assert html =~ ws.name
      refute html =~ ~s(name="confirm_email")
    end

    test "confirm state shows form, button disabled until email matches", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/settings/data")

      settings_view = find_live_child(view, "detail-settings-data")

      html =
        settings_view
        |> element("button[phx-click='open_delete_account_modal']")
        |> render_click()

      assert html =~ ~s(name="confirm_email")
      assert html =~ ~s(disabled)

      # Type wrong email: still disabled
      html =
        settings_view
        |> form("form#delete-account-form", %{"confirm_email" => "wrong"})
        |> render_change()

      assert html =~ ~s(disabled)

      # Type correct email: enabled
      html =
        settings_view
        |> form("form#delete-account-form", %{"confirm_email" => to_string(user.email)})
        |> render_change()

      refute html =~ ~s(disabled="disabled")
    end
  end
end
