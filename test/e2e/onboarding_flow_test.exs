defmodule MagusWeb.E2E.OnboardingFlowTest do
  @moduledoc """
  Browser-based E2E tests for the full onboarding journey.

  Tests the end-to-end chain from registration/magic link all the way
  through to the chat interface. Unlike the individual flow tests
  (registration_flow_test, magic_link_flow_test), these tests verify
  the complete onboarding journey as a single user experience.
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

  defp submit_magic_link_confirm_form(conn) do
    # Submit the magic link confirm form with a native POST.
    #
    # Similar to the registration form, using requestSubmit() is unreliable
    # with LiveView because of form locks from in-flight events. Instead, we
    # construct a native form POST directly.
    {:ok, _} =
      PlaywrightEx.Frame.evaluate(conn.frame_id,
        expression: """
        new Promise((resolve) => {
          setTimeout(() => {
            const form = document.getElementById('magic-link-confirm-form');
            const action = form.getAttribute('action');
            const method = form.getAttribute('method');

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

  defp submit_complete_profile_form(conn) do
    # Submit the complete-profile form with checkboxes checked.
    #
    # The complete-profile form is a LiveView form with phx-submit="save".
    # We set checkbox values directly and trigger a click on the submit button.
    {:ok, _} =
      PlaywrightEx.Frame.evaluate(conn.frame_id,
        expression: """
        new Promise((resolve) => {
          setTimeout(() => {
            const form = document.getElementById('complete-profile-form');

            // Set checkbox values directly in the DOM
            const termsCheckbox = form.querySelector('input[name="user[accepted_terms]"]');
            const ageCheckbox = form.querySelector('input[name="user[accepted_age_requirement]"]');
            if (termsCheckbox) termsCheckbox.checked = true;
            if (ageCheckbox) ageCheckbox.checked = true;

            // Dispatch change events so LiveView picks them up
            if (termsCheckbox) termsCheckbox.dispatchEvent(new Event('change', { bubbles: true }));
            if (ageCheckbox) ageCheckbox.dispatchEvent(new Event('change', { bubbles: true }));

            // Wait for LiveView to process checkbox changes, then submit
            setTimeout(() => {
              form.querySelector('button[type="submit"]').click();
              resolve('submitted');
            }, 500);
          }, 200);
        })
        """,
        timeout: 10_000
      )

    conn
  end

  # Fill the password field and submit the sign-in form via JS.
  #
  # PhoenixTest.Playwright's fill_in/4 does not reliably fill password inputs
  # inside wrapping <label> elements within a `within` scope. Instead, we set
  # the password via the native value setter and click the submit button via JS.
  # This matches the approach used in sign_in_flow_test.exs.
  defp fill_password_and_submit_sign_in(conn, password) do
    {:ok, _} =
      PlaywrightEx.Frame.evaluate(conn.frame_id,
        expression: """
        new Promise((resolve) => {
          const form = document.getElementById('password-sign-in-form');
          const passInput = form.querySelector('input[name="user[password]"]');

          // Set password via native setter to bypass LiveView value protection.
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

  describe "full onboarding journey: register -> confirm -> sign in -> chat" do
    test "register with password, confirm email, sign out, sign back in, see chat", %{
      conn: conn
    } do
      email = "e2e-onboard-#{System.unique_integer([:positive])}@test.com"

      # --- Step 1: Register a new account ---
      drain_emails()

      conn =
        conn
        |> visit(~p"/register")
        |> assert_has("h1", text: "Create your account")
        |> assert_has(".phx-connected")
        |> fill_in("Name", with: "Onboarding User")
        |> fill_in("Email", with: email)
        |> fill_in("Password", with: @password)
        |> fill_in("Confirm Password", with: @password)

      # Wait for LiveView to process all fill_in change events
      Process.sleep(1_000)

      conn = submit_registration_form(conn)

      # After registration, the native form POST creates the user, logs them in,
      # and redirects to /chat.
      conn = assert_path(conn, "/next", timeout: 15_000)

      # --- Step 2: Confirm the email address ---
      assert {:ok, confirmation_email} = find_email(:mail_verification, timeout: 5_000)
      confirmation_url = extract_action_url(confirmation_email)
      assert confirmation_url =~ "/confirm_new_user/"

      confirmation_path = extract_path(confirmation_url)

      conn =
        conn
        |> visit(confirmation_path)
        |> click("button[type='submit']")
        |> assert_has("[role='alert']", text: "confirmed")

      # Welcome email should be sent after confirmation
      assert_welcome_email_sent()

      # --- Step 3: Sign out ---
      conn = visit(conn, ~p"/sign-out")

      # Sign-out redirects to "/" which redirects to a locale-specific home page.
      # Wait for the redirect chain to settle.
      Process.sleep(2_000)

      # --- Step 4: Sign back in with password ---
      drain_emails()

      conn =
        conn
        |> visit(~p"/sign-in")
        |> assert_has("#password-sign-in-form", timeout: 10_000)
        |> assert_has(".phx-connected")

      # Fill email via fill_in (works reliably), then fill password and submit
      # via JS evaluation because fill_in for password inputs inside wrapping
      # <label> elements within a `within` scope is unreliable.
      conn =
        conn
        |> within("#password-sign-in-form", fn form_conn ->
          fill_in(form_conn, "Email", with: email)
        end)

      # Wait for email blur/change to be processed
      Process.sleep(500)

      conn = fill_password_and_submit_sign_in(conn, @password)

      # --- Step 5: Verify we land in the chat interface ---
      conn = assert_path(conn, "/next", timeout: 10_000)

      assert_has(conn, "p", text: "What's on your mind today?", timeout: 10_000)
    end
  end

  describe "magic link onboarding journey: magic link -> profile -> chat" do
    test "new user signs in via magic link, completes profile, lands in chat", %{conn: conn} do
      email = "e2e-magic-onboard-#{System.unique_integer([:positive])}@test.com"

      # --- Step 1: Request a magic link ---
      drain_emails()

      conn =
        conn
        |> visit(~p"/sign-in")
        |> assert_has(".phx-connected")

      conn =
        conn
        |> within("form[phx-submit='request_magic_link']", fn form_conn ->
          form_conn
          |> fill_in("Email", with: email)
          |> click_button("Request magic link")
        end)

      conn = assert_has(conn, ".alert-success", text: "Check your email", timeout: 5_000)

      # --- Step 2: Click the magic link and confirm sign-in ---
      assert {:ok, magic_link_email} = find_email(:magic_link, timeout: 5_000)
      magic_link_url = extract_action_url(magic_link_email)
      assert magic_link_url =~ "/magic_link/"

      magic_link_path = extract_path(magic_link_url)

      conn =
        conn
        |> visit(magic_link_path)
        |> assert_has("#magic-link-confirm-form", timeout: 10_000)
        |> assert_has(".phx-connected")

      # Wait for LiveView to be fully connected before submitting
      Process.sleep(1_000)

      conn = submit_magic_link_confirm_form(conn)

      # New user (accepted_terms: false) redirects to /complete-profile
      conn = assert_path(conn, "/complete-profile", timeout: 15_000)

      # --- Step 3: Complete the profile ---
      drain_emails()

      conn =
        conn
        |> assert_has("#complete-profile-form", timeout: 10_000)
        |> assert_has(".phx-connected")
        |> fill_in("Name", with: "Magic Link Onboarder")

      # Wait for LiveView to process fill_in change events
      Process.sleep(1_000)

      conn = submit_complete_profile_form(conn)

      # --- Step 4: Verify we land in the chat interface ---
      conn = assert_path(conn, "/next", timeout: 15_000)

      conn = assert_has(conn, "p", text: "What's on your mind today?", timeout: 10_000)

      # Welcome email should be sent after profile completion
      assert_welcome_email_sent(timeout: 5_000)

      # Verify the user can see the chat input area (fully functional)
      assert_has(conn, "#chat-textarea", timeout: 5_000)
    end
  end

  describe "incomplete profile redirect guard" do
    test "user without completed profile is redirected to complete-profile page", %{conn: conn} do
      # Create a user with accepted_terms: true (required by register_with_password
      # validation), then force accepted_terms to false to simulate a magic link
      # user who hasn't completed their profile yet.
      user = generate(user())

      user =
        user
        |> Ash.Changeset.for_update(:update_profile, %{})
        |> Ash.Changeset.force_change_attribute(:confirmed_at, DateTime.utc_now())
        |> Ash.Changeset.force_change_attribute(:accepted_terms, false)
        |> Ash.update!(authorize?: false)

      # Authenticate the browser session as this user
      conn = authenticate(conn, user)

      # --- Step 1: Try to access /chat directly ---
      conn = visit(conn, ~p"/chat")

      # The LiveUserAuth :live_user_required guard should redirect to /complete-profile
      # because accepted_terms is false.
      conn = assert_path(conn, "/complete-profile", timeout: 10_000)

      # --- Step 2: Verify the complete-profile form is shown ---
      conn =
        conn
        |> assert_has("#complete-profile-form", timeout: 10_000)
        |> assert_has("h2", text: "Complete Your Profile")

      # --- Step 3: Complete the profile and verify redirect to chat ---
      conn = fill_in(conn, "Name", with: "Profile Completer")

      Process.sleep(1_000)

      conn = submit_complete_profile_form(conn)

      conn = assert_path(conn, "/next", timeout: 15_000)

      assert_has(conn, "p", text: "What's on your mind today?", timeout: 10_000)
    end
  end
end
