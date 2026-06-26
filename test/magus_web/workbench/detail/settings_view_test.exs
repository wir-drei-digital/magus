defmodule MagusWeb.Workbench.Detail.SettingsViewTest do
  use MagusWeb.LiveViewCase, async: false

  import Phoenix.LiveViewTest
  import MagusWeb.LiveViewCase
  import Magus.Generators

  describe "GET /settings" do
    test "renders profile section by default", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ ~s(data-settings-section="profile")
    end

    test "renders preferences section at /settings/preferences", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/settings/preferences")
      assert html =~ ~s(data-settings-section="preferences")
    end

    test "renders storage section", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/settings/storage")
      assert html =~ ~s(data-settings-section="storage")
    end

    test "renders data section", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/settings/data")
      assert html =~ ~s(data-settings-section="data")
    end

    test "renders subscription section", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/settings/subscription")
      assert html =~ ~s(data-settings-section="subscription")
    end

    test "renders integrations section", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/settings/integrations")
      assert html =~ ~s(data-settings-section="integrations")
    end

    test "renders knowledge section", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/settings/knowledge")
      assert html =~ ~s(data-settings-section="knowledge")
    end

    test "settings sub-nav highlights active section", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/settings/storage")
      assert html =~ ~s(data-detail-section="storage")
    end
  end

  describe "context strategy preference" do
    test "preferences section renders the context strategy control", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)
      {:ok, _view, html} = live(conn, ~p"/settings/preferences")

      assert html =~ ~s(data-role="settings-context-strategy")
      assert html =~ "select_context_strategy"
    end

    test "selecting Compact persists context_strategy on the user", %{conn: conn} do
      user = generate(user())
      assert user.context_strategy == nil

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/settings/preferences")

      # SettingsView is a child LiveView (live_render); drive events on the child.
      section = find_live_child(view, "detail-settings-preferences")

      section
      |> form(~s([data-role="settings-context-strategy"]), %{"context_strategy" => "compact"})
      |> render_change()

      reloaded = Magus.Accounts.get_user!(user.id, authorize?: false)
      assert reloaded.context_strategy == :compact
    end

    test "selecting the default option clears context_strategy to nil", %{conn: conn} do
      user = generate(user())

      {:ok, user} =
        Magus.Accounts.update_user_settings(user, %{context_strategy: :compact}, actor: user)

      assert user.context_strategy == :compact

      conn = log_in_user(conn, user)
      {:ok, view, _html} = live(conn, ~p"/settings/preferences")

      section = find_live_child(view, "detail-settings-preferences")

      section
      |> form(~s([data-role="settings-context-strategy"]), %{"context_strategy" => ""})
      |> render_change()

      reloaded = Magus.Accounts.get_user!(user.id, authorize?: false)
      assert reloaded.context_strategy == nil
    end
  end
end
