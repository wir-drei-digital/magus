defmodule MagusWeb.E2E.SettingsTest do
  @moduledoc """
  Browser-based E2E tests for the user settings page.

  Tests profile editing, language switching, and email display. All tests
  use authenticated sessions with confirmed users -- no LLM calls needed.
  """
  use MagusWeb.PlaywrightCase

  @moduletag :e2e

  describe "user settings" do
    test "settings page renders with user info", %{conn: conn} do
      user = generate(user(name: "Settings Test User")) |> confirm_user()

      conn
      |> authenticate(user)
      |> visit(~p"/settings")
      |> assert_has(".phx-connected")
      |> assert_has("h1", text: "Settings")
      |> assert_has("body", text: "Profile")
      |> assert_has("body", text: "Email")
      |> assert_has("body", text: "Password")
    end

    test "settings page shows current email", %{conn: conn} do
      email = "settings-email-#{System.unique_integer([:positive])}@test.com"
      user = generate(user(email: email)) |> confirm_user()

      conn
      |> authenticate(user)
      |> visit(~p"/settings")
      |> assert_has(".phx-connected")
      |> assert_has("body", text: "Current email:")
      |> assert_has("span.font-medium", text: email)
    end

    test "user can update display name", %{conn: conn} do
      user = generate(user(name: "Original Name")) |> confirm_user()

      conn
      |> authenticate(user)
      |> visit(~p"/settings")
      |> assert_has(".phx-connected")
      |> fill_in("Display Name", with: "Updated Display Name")
      |> click_button("Save Profile")
      |> assert_has("[role='alert']", text: "Profile updated successfully", timeout: 5_000)
    end

    test "user can change language preference and see UI change", %{conn: conn} do
      user = generate(user(name: "Language Tester", language: :en)) |> confirm_user()

      conn =
        conn
        |> authenticate(user)
        |> visit(~p"/settings")
        |> assert_has(".phx-connected")

      # Verify English UI is displayed
      conn = assert_has(conn, "h1", text: "Settings")
      conn = assert_has(conn, "button", text: "Save Profile")

      # Change language to German and submit
      conn =
        conn
        |> select("Language", exact: false, option: "Deutsch")
        |> click_button("Save Profile")

      # The flash message is rendered in German because put_flash is called
      # after Gettext.put_locale in the event handler, so gettext picks up
      # the new locale for the flash text.
      conn =
        assert_has(conn, "[role='alert']",
          text: "Profil erfolgreich aktualisiert",
          timeout: 10_000
        )

      # However, static gettext() calls in the template (h1, buttons, labels)
      # are NOT re-evaluated after the event because LiveView's change tracking
      # optimization treats expressions without assign dependencies as unchanged.
      # A fresh page visit triggers a full re-mount where all gettext() calls
      # are evaluated with the persisted user locale from the database.
      conn
      |> visit(~p"/settings")
      |> assert_has(".phx-connected")
      |> assert_has("h1", text: "Einstellungen", timeout: 5_000)
      |> assert_has("button", text: "Profil speichern", timeout: 5_000)
    end
  end
end
