defmodule MagusWeb.OnboardingLive.SignInLiveTest do
  use MagusWeb.LiveViewCase, async: false

  import MagusWeb.LiveViewCase
  import Mox

  alias Magus.Usage

  setup do
    {:ok, _free_plan} =
      Usage.create_usage_plan(
        %{
          key: "free",
          name: "Free",
          storage_bytes: 1_000_000_000,
          max_upload_bytes: 10_000_000,
          is_active: true,
          sort_order: 0
        },
        authorize?: false
      )

    :ok
  end

  describe "mount" do
    test "renders sign-in page with both forms", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sign-in")

      # Password form elements
      assert html =~ "Sign in"
      assert html =~ "Email"
      assert html =~ "Password"
      assert html =~ "Forgot your password?"
      assert html =~ "Need an account?"

      # Magic link section
      assert html =~ "Request magic link"
    end

    test "redirects authenticated user to home", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/sign-in")
    end

    test "preserves plan parameter in register link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sign-in?plan=starter")

      assert html =~ "/register?plan=starter"
    end
  end

  describe "password form validation" do
    test "validates password form on change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sign-in")

      html =
        view
        |> form("#password-sign-in-form",
          user: %{
            email: "test@example.com",
            password: "password123"
          }
        )
        |> render_change()

      # Should render without errors on valid input
      assert html =~ "test@example.com"
    end
  end

  describe "password sign-in submission" do
    test "shows error for invalid credentials", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sign-in")

      html =
        view
        |> form("#password-sign-in-form",
          user: %{
            email: "nonexistent@example.com",
            password: "WrongPassword123!"
          }
        )
        |> render_submit()

      # Error is shown inline on the form field by AshPhoenix
      assert html =~ "incorrect" or html =~ "Invalid"
    end

    test "triggers form action on valid credentials", %{conn: conn} do
      email = unique_email()
      password = "ValidPassword123!"

      # Create a user first
      generate(user(email: email, password: password))

      {:ok, view, _html} = live(conn, ~p"/sign-in")

      # Submit valid credentials - should trigger the phx-trigger-action
      # which causes a redirect (form POST to auth controller)
      view
      |> form("#password-sign-in-form",
        user: %{
          email: email,
          password: password
        }
      )
      |> render_submit()

      # After successful validation, trigger_action is set to true
      # which causes the form to POST to the auth controller.
      # In test, we verify the form has phx-trigger-action set.
      html = render(view)
      assert html =~ "phx-trigger-action"
    end
  end

  describe "magic link request" do
    test "shows success message after requesting magic link", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sign-in")

      html =
        view
        |> element("form[phx-submit='request_magic_link']")
        |> render_submit(%{email: "user@example.com"})

      assert html =~ "Check your email for a sign-in link!"
      # Magic link form should be hidden after sending
      refute html =~ "Request magic link"
    end

    test "shows success even for non-existent email (security)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sign-in")

      html =
        view
        |> element("form[phx-submit='request_magic_link']")
        |> render_submit(%{email: "doesnotexist@example.com"})

      # Should still show success (don't leak whether email exists)
      assert html =~ "Check your email for a sign-in link!"
    end
  end

  describe "rate limiting (signup-abuse hardening)" do
    setup do
      original = Application.get_env(:magus, :auth_rate_limits)
      on_exit(fn -> Application.put_env(:magus, :auth_rate_limits, original) end)
      :ok
    end

    test "password sign-in over the limit shows a flash and does not submit", %{conn: conn} do
      Application.put_env(:magus, :auth_rate_limits, enabled: true, sign_in: {0, :minute})

      # Valid credentials for an existing user: if the sign-in action ran, this
      # would succeed and flip trigger_action to true. It must not run.
      email = unique_email()
      password = "ValidPassword123!"
      generate(user(email: email, password: password))

      {:ok, view, _html} = live(conn, ~p"/sign-in")

      html =
        view
        |> form("#password-sign-in-form",
          user: %{
            email: email,
            password: password
          }
        )
        |> render_submit()

      assert html =~ "Too many attempts"
      refute html =~ "phx-trigger-action"
    end

    test "magic-link request over the limit shows an error flash instead of success", %{
      conn: conn
    } do
      Application.put_env(:magus, :auth_rate_limits, enabled: true, magic_link: {0, :hour})

      {:ok, view, _html} = live(conn, ~p"/sign-in")

      html =
        view
        |> element("form[phx-submit='request_magic_link']")
        |> render_submit(%{email: "user@example.com"})

      assert html =~ "Too many requests"
      refute html =~ "Check your email for a sign-in link!"
    end
  end

  describe "captcha (signup-abuse hardening)" do
    setup :verify_on_exit!

    setup do
      original = Application.get_env(:magus, :captcha)
      on_exit(fn -> Application.put_env(:magus, :captcha, original) end)
      :ok
    end

    defp enable_captcha! do
      Application.put_env(:magus, :captcha,
        impl: Magus.CaptchaImplMock,
        site_key: "sk",
        secret_key: "sec"
      )
    end

    test "widget is absent when captcha is disabled (the default)", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/sign-in")

      refute html =~ "cf-turnstile"
    end

    test "widget is present when captcha is enabled", %{conn: conn} do
      enable_captcha!()

      {:ok, _view, html} = live(conn, ~p"/sign-in")

      assert html =~ "cf-turnstile"
      # The widget must render OUR configured site key, not phoenix_turnstile's
      # own default (Cloudflare's always-pass TEST key) — proves the coupling
      # to Magus.Captcha.site_key/0 is wired, not accidentally relying on the
      # boot-time copy into :phoenix_turnstile app env.
      assert html =~ ~s(data-sitekey="sk")
    end

    test "magic-link request without a token shows a captcha error and does not send", %{
      conn: conn
    } do
      enable_captcha!()

      {:ok, view, _html} = live(conn, ~p"/sign-in")

      html =
        view
        |> element("form[phx-submit='request_magic_link']")
        |> render_submit(%{email: "user@example.com"})

      assert html =~ "Captcha verification failed"
      refute html =~ "Check your email for a sign-in link!"
    end

    test "magic-link request with a valid token succeeds", %{conn: conn} do
      enable_captcha!()

      expect(Magus.CaptchaImplMock, :verify, fn %{"cf-turnstile-response" => "tok"}, _ip ->
        {:ok, %{"success" => true}}
      end)

      {:ok, view, _html} = live(conn, ~p"/sign-in")

      html =
        view
        |> element("form[phx-submit='request_magic_link']")
        |> render_submit(%{"email" => "user@example.com", "cf-turnstile-response" => "tok"})

      assert html =~ "Check your email for a sign-in link!"
    end

    test "magic-link request whose verification is unavailable shows the distinct flash", %{
      conn: conn
    } do
      enable_captcha!()

      expect(Magus.CaptchaImplMock, :verify, fn %{"cf-turnstile-response" => "tok"}, _ip ->
        {:error, :timeout}
      end)

      {:ok, view, _html} = live(conn, ~p"/sign-in")

      html =
        view
        |> element("form[phx-submit='request_magic_link']")
        |> render_submit(%{"email" => "user@example.com", "cf-turnstile-response" => "tok"})

      assert html =~ "temporarily unavailable"
      refute html =~ "Check your email for a sign-in link!"
    end
  end
end
