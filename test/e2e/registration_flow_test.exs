defmodule MagusWeb.E2E.RegistrationFlowTest do
  @moduledoc """
  Browser-based E2E tests for the password registration flow.

  Tests the complete journey: register -> confirmation email -> confirm email ->
  welcome email -> sign in.
  """
  use MagusWeb.PlaywrightCase

  import MagusWeb.EmailHelpers

  @moduletag :e2e

  @password "TestPassword123!"

  setup do
    setup_email_delivery()
    :ok
  end

  defp submit_registration_form(conn) do
    # Submit the registration form with checkboxes checked via native POST.
    #
    # Using requestSubmit() is unreliable with LiveView because:
    #   - LiveView may have a form lock from in-flight phx-change events
    #   - Checkbox DOM state may be reset by LiveView re-renders
    #
    # Instead, we construct a native form POST directly. This bypasses
    # LiveView's phx-submit entirely and goes straight to the auth
    # controller, which is what phx-trigger-action would do anyway.
    {:ok, _} =
      PlaywrightEx.Frame.evaluate(conn.frame_id,
        expression: """
        new Promise((resolve) => {
          // Small delay to ensure all input values are settled in the DOM
          setTimeout(() => {
            const form = document.getElementById('register-form');
            const action = form.getAttribute('action');
            const method = form.getAttribute('method');

            // Build a new form with all current field values plus checkboxes
            const postForm = document.createElement('form');
            postForm.method = method;
            postForm.action = action;
            postForm.style.display = 'none';

            // Copy all inputs from the LiveView form
            const formData = new FormData(form);
            for (const [name, value] of formData.entries()) {
              const input = document.createElement('input');
              input.type = 'hidden';
              input.name = name;
              input.value = value;
              postForm.appendChild(input);
            }

            // Ensure checkbox values are set (they might be missing from FormData)
            if (!formData.has('user[accepted_terms]')) {
              const input = document.createElement('input');
              input.type = 'hidden';
              input.name = 'user[accepted_terms]';
              input.value = 'true';
              postForm.appendChild(input);
            }
            if (!formData.has('user[accepted_age_requirement]')) {
              const input = document.createElement('input');
              input.type = 'hidden';
              input.name = 'user[accepted_age_requirement]';
              input.value = 'true';
              postForm.appendChild(input);
            }

            document.body.appendChild(postForm);
            postForm.submit();
            resolve('submitted');
          }, 500);
        })
        """,
        timeout: 10_000
      )

    conn
  end

  describe "password registration flow" do
    test "full registration through email confirmation", %{conn: conn} do
      email = "e2e-register-#{System.unique_integer([:positive])}@test.com"

      # --- Step 1: Register ---
      drain_emails()

      conn =
        conn
        |> visit(~p"/register")
        |> assert_has("h1", text: "Create your account")
        |> assert_has(".phx-connected")
        |> fill_in("Name", with: "E2E Test User")
        |> fill_in("Email", with: email)
        |> fill_in("Password", with: @password)
        |> fill_in("Confirm Password", with: @password)

      # Wait for LiveView to process all fill_in change events
      Process.sleep(1_000)

      conn = submit_registration_form(conn)

      # After registration, the native form POST goes to the auth controller
      # which creates the user, logs them in, and redirects.

      conn = assert_path(conn, "/chat", timeout: 15_000)

      # Confirmation email should be sent
      assert {:ok, confirmation_email} = find_email(:mail_verification, timeout: 5_000)
      confirmation_url = extract_action_url(confirmation_email)
      assert confirmation_url =~ "/confirm_new_user/"

      # No welcome email yet (not confirmed)
      assert_no_welcome_email()

      # --- Step 2: Confirm email ---
      # The confirm_route renders a page with a "Confirm" submit button
      # (require_interaction? is true). Clicking it POSTs to the auth controller
      # which confirms the user and redirects to /chat with a flash.
      confirmation_path = extract_path(confirmation_url)

      conn =
        conn
        |> visit(confirmation_path)
        |> click("button[type='submit']")
        |> assert_has("[role='alert']", text: "confirmed")

      # Welcome email should now be sent (user is fully onboarded)
      assert_welcome_email_sent()

      # --- Step 3: Sign out and sign back in ---
      conn = visit(conn, ~p"/sign-out")

      # Sign-out redirects to "/" which redirects to a locale-specific home page.
      # Wait for the redirect chain to settle before navigating to sign-in.
      Process.sleep(2_000)

      drain_emails()

      conn = visit(conn, ~p"/sign-in")

      conn =
        conn
        |> assert_has("#password-sign-in-form", timeout: 10_000)
        |> assert_has(".phx-connected")

      # Use `within` to scope to the password form, since the sign-in page
      # has two Email inputs (password form + magic link form). Using
      # fill_in("#form-id", "Label", ...) uses Playwright's `and` operator
      # which fails with wrapping <label> elements. `within` uses the `>>`
      # (descendant) operator which works correctly.
      # Note: click/2 doesn't respect `within` scope, so use click_button/2.
      conn
      |> within("#password-sign-in-form", fn form_conn ->
        form_conn
        |> fill_in("Email", with: email)
        |> fill_in("Password", with: @password)
        |> click_button("Sign in")
      end)
      |> assert_path("/chat", timeout: 10_000)
    end

    test "registration shows error for mismatched passwords", %{conn: conn} do
      # Fill out the form with mismatched passwords.
      # LiveView's phx-change="validate" handler shows validation errors
      # in real-time. After filling in mismatched passwords and blurring
      # the confirm password field, a validation error should appear.
      conn
      |> visit(~p"/register")
      |> assert_has(".phx-connected")
      |> fill_in("Name", with: "Test User")
      |> fill_in("Email", with: "validation-test@example.com")
      |> fill_in("Password", with: "ValidPassword123!")
      |> fill_in("Confirm Password", with: "DifferentPassword!")
      |> assert_has("p.text-error", text: "does not match", timeout: 5_000)
    end
  end
end
