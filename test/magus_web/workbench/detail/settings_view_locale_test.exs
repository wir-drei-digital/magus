defmodule MagusWeb.Workbench.Detail.SettingsViewLocaleTest do
  use MagusWeb.LiveViewCase, async: false

  import Phoenix.LiveViewTest
  import MagusWeb.LiveViewCase
  import Magus.Generators

  # Regression: the settings detail view is a child `live_render` running in its
  # own process. On the *connected* mount it must restore the Gettext locale
  # resolved by the parent WorkbenchLive; otherwise it falls back to the default
  # ("en") and the page flickers from the user's language (German) to English.
  describe "locale restoration in the settings child LiveView" do
    setup %{conn: conn} do
      user = generate(user(language: :de))
      %{conn: log_in_user(conn, user), user: user}
    end

    test "usage section renders in the user's language", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings/usage")
      child = find_live_child(view, "detail-settings-usage")
      assert render(child) =~ ~s(data-locale="de")
    end

    test "subscription section renders in the user's language", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings/subscription")
      child = find_live_child(view, "detail-settings-subscription")
      assert render(child) =~ ~s(data-locale="de")
    end
  end
end
