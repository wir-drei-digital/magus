defmodule MagusWeb.OnboardingLive.MagicLinkConfirmLiveTest do
  use MagusWeb.LiveViewCase, async: false

  import MagusWeb.LiveViewCase

  describe "mount" do
    test "renders confirmation page with token", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/magic_link/some-test-token")

      assert html =~ "Complete your sign-in"
      assert html =~ "Click the button below to sign in"
      assert html =~ "Sign In"
      # Token should be in hidden field
      assert html =~ "some-test-token"
    end

    test "redirects authenticated user to home", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/magic_link/some-token")
    end
  end

  describe "confirm_sign_in" do
    test "sets trigger_action on submit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/magic_link/test-token-abc")

      html =
        view
        |> element("#magic-link-confirm-form")
        |> render_submit()

      # After submit, trigger_action should be true, causing the form to POST
      assert html =~ "phx-trigger-action"
    end

    test "includes CSRF token in form", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/magic_link/test-token")

      assert html =~ "_csrf_token"
    end

    test "posts to correct auth endpoint", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/magic_link/test-token")

      assert html =~ ~s(action="/auth/user/magic_link")
    end
  end
end
