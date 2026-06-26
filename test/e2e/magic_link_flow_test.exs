defmodule MagusWeb.E2E.MagicLinkFlowTest do
  @moduledoc """
  Browser-based E2E tests for the magic link sign-in flow.

  Tests the complete journey: request magic link -> email sent -> click link ->
  sign in -> profile completion (new users) -> welcome email.
  """
  use MagusWeb.PlaywrightCase

  import MagusWeb.EmailHelpers

  @moduletag :e2e

  setup do
    setup_email_delivery()
    :ok
  end

  defp submit_magic_link_confirm_form(conn) do
    # Submit the magic link confirm form with a native POST.
    #
    # Similar to the registration test, using requestSubmit() is unreliable
    # with LiveView because of form locks from in-flight events. Instead, we
    # construct a native form POST directly. This bypasses LiveView's
    # phx-submit entirely and goes straight to the auth controller, which is
    # what phx-trigger-action would do anyway.
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

  describe "magic link flow for new user" do
    test "full magic link sign-in with profile completion", %{conn: conn} do
      email = "e2e-magic-#{System.unique_integer([:positive])}@test.com"

      # --- Step 1: Request magic link ---
      drain_emails()

      conn =
        conn
        |> visit(~p"/sign-in")
        |> assert_has(".phx-connected")

      # The magic link form is below the divider. Use `within` to scope to it
      # since the sign-in page has two "Email" inputs.
      conn =
        conn
        |> within("form[phx-submit='request_magic_link']", fn form_conn ->
          form_conn
          |> fill_in("Email", with: email)
          |> click_button("Request magic link")
        end)

      conn = assert_has(conn, ".alert-success", text: "Check your email", timeout: 5_000)

      # Magic link email should be sent
      assert {:ok, magic_link_email} = find_email(:magic_link, timeout: 5_000)
      magic_link_url = extract_action_url(magic_link_email)
      assert magic_link_url =~ "/magic_link/"

      # No welcome email yet
      assert_no_welcome_email()

      # --- Step 2: Click magic link and confirm sign-in ---
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

      # --- Step 3: Complete profile ---
      drain_emails()

      conn =
        conn
        |> assert_has("#complete-profile-form", timeout: 10_000)
        |> assert_has(".phx-connected")
        |> fill_in("Name", with: "Magic Link User")

      # Wait for LiveView to process fill_in change events
      Process.sleep(1_000)

      # Submit the profile form with checkboxes checked via native POST.
      # The complete-profile form is an AshPhoenix form with phx-submit="save".
      # Unlike the registration form, it does NOT have phx-trigger-action,
      # so we can use LiveView's phx-submit directly.
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

      # Should redirect to /chat after profile completion
      _conn = assert_path(conn, "/chat", timeout: 15_000)

      # Welcome email should now be sent
      assert_welcome_email_sent(timeout: 5_000)
    end
  end

  describe "magic link flow for returning user" do
    test "existing user skips profile completion", %{conn: conn} do
      # Create a fully onboarded user (accepted_terms: true by default).
      # Must also confirm the user's email — the magic link upsert has a
      # hijack prevention filter that rejects unconfirmed users (even though
      # sign_in_with_magic_link is in auto_confirm_actions, the filter still
      # checks confirmed_at when the email identity is matched).
      user = generate(user())

      user =
        user
        |> Ash.Changeset.for_update(:update_profile, %{})
        |> Ash.Changeset.force_change_attribute(:confirmed_at, DateTime.utc_now())
        |> Ash.update!(authorize?: false)

      email = to_string(user.email)

      # --- Step 1: Request magic link ---
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

      # Magic link email should be sent
      assert {:ok, magic_link_email} = find_email(:magic_link, timeout: 5_000)
      magic_link_url = extract_action_url(magic_link_email)
      magic_link_path = extract_path(magic_link_url)

      # --- Step 2: Click magic link and confirm sign-in ---
      conn =
        conn
        |> visit(magic_link_path)
        |> assert_has("#magic-link-confirm-form", timeout: 10_000)
        |> assert_has(".phx-connected")

      # Wait for LiveView to be fully connected before submitting
      Process.sleep(1_000)

      conn = submit_magic_link_confirm_form(conn)

      # Existing user with accepted_terms=true goes straight to /chat
      assert_path(conn, "/chat", timeout: 15_000)
    end
  end
end
