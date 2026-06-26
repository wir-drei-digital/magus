defmodule MagusWeb.E2E.SignInFlowTest do
  @moduledoc """
  Browser-based E2E tests for password sign-in, sign-out, and auth guards.
  """
  use MagusWeb.PlaywrightCase

  @moduletag :e2e

  @password "TestPassword123!"

  # Fill the sign-in form fields and submit via native POST.
  #
  # PhoenixTest.Playwright's fill_in/4 does not reliably fill password inputs
  # inside wrapping <label> elements within a `within` scope, and click_button
  # within a re-entered `within` scope can also be unreliable. Instead, we:
  #   1. Fill email via fill_in (works reliably for email)
  #   2. Fill password via Playwright's Frame.fill with a CSS selector
  #   3. Submit by clicking the button via JS
  #
  # This matches the approach used in the registration test's sign-in step,
  # adapted for the password fill issue.
  defp fill_and_submit_sign_in(conn, password) do
    {:ok, _} =
      PlaywrightEx.Frame.evaluate(conn.frame_id,
        expression: """
        new Promise((resolve) => {
          const form = document.getElementById('password-sign-in-form');
          const passInput = form.querySelector('input[name="user[password]"]');

          // Set password via native setter to bypass LiveView value protection.
          // Playwright's fill_in does not reliably fill password inputs inside
          // wrapping <label> elements within a `within` scope.
          const nativeSet = Object.getOwnPropertyDescriptor(
            window.HTMLInputElement.prototype, 'value'
          ).set;
          nativeSet.call(passInput, '#{String.replace(password, "'", "\\'")}');
          passInput.dispatchEvent(new Event('input', { bubbles: true }));
          passInput.dispatchEvent(new Event('change', { bubbles: true }));

          // Small delay to let LiveView process the change events, then click submit
          setTimeout(() => {
            form.querySelector('button[type="submit"]').click();
            resolve('submitted');
          }, 500);
        })
        """,
        timeout: 10_000
      )

    conn
  end

  describe "password sign-in" do
    test "successful sign-in redirects to chat", %{conn: conn} do
      user = generate(user(password: @password))
      email = to_string(user.email)

      conn =
        conn
        |> visit(~p"/sign-in")
        |> assert_has("#password-sign-in-form", timeout: 10_000)
        |> assert_has(".phx-connected")
        |> within("#password-sign-in-form", fn form_conn ->
          fill_in(form_conn, "Email", with: email)
        end)

      # Wait for email blur/change to be processed
      Process.sleep(500)

      conn = fill_and_submit_sign_in(conn, @password)

      assert_path(conn, "/chat", timeout: 15_000)
    end

    test "invalid credentials show error", %{conn: conn} do
      user = generate(user(password: @password))
      email = to_string(user.email)

      conn =
        conn
        |> visit(~p"/sign-in")
        |> assert_has("#password-sign-in-form", timeout: 10_000)
        |> assert_has(".phx-connected")
        |> within("#password-sign-in-form", fn form_conn ->
          fill_in(form_conn, "Email", with: email)
        end)

      # Wait for email blur/change to be processed
      Process.sleep(500)

      conn = fill_and_submit_sign_in(conn, "WrongPassword123!")

      # The LiveView handles password_sign_in event — on failure, Form.submit
      # returns {:error, form} and the form re-renders with an inline error.
      # The error message comes from AshAuthentication's sign_in_with_password action.
      conn
      |> assert_has("#password-sign-in-form", text: "incorrect", timeout: 10_000)
    end
  end

  describe "sign-out" do
    test "sign-out redirects to home", %{conn: conn} do
      user = generate(user())

      conn =
        conn
        |> authenticate(user)
        |> visit(~p"/chat")
        |> assert_path("/chat", timeout: 10_000)

      conn = visit(conn, ~p"/sign-out")

      # Sign-out redirects to "/" which redirects to a locale-specific home page.
      # Wait for the redirect chain to settle.
      Process.sleep(2_000)

      # After sign-out, visiting /chat should redirect to /sign-in
      conn
      |> visit(~p"/chat")
      |> assert_path("/sign-in", timeout: 10_000)
    end
  end

  describe "auth guards" do
    test "unauthenticated user visiting /chat is redirected to /sign-in", %{conn: conn} do
      conn
      |> visit(~p"/chat")
      |> assert_path("/sign-in", timeout: 10_000)
    end
  end
end
