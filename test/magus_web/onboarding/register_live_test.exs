defmodule MagusWeb.OnboardingLive.RegisterLiveTest do
  use MagusWeb.LiveViewCase, async: false

  import MagusWeb.LiveViewCase

  alias Magus.Usage

  setup do
    # Create a free plan for user registration
    {:ok, free_plan} =
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

    {:ok, free_plan: free_plan}
  end

  describe "mount" do
    test "renders registration form with free plan by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/register")

      assert html =~ "Create your account"
      assert html =~ "Create Account"
      refute html =~ "Selected plan:"
    end

    test "renders registration form with starter plan when specified", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/register?plan=starter")

      assert html =~ "Create your account"
      assert html =~ "Selected plan:"
      assert html =~ "Starter"
      assert html =~ "Continue to Payment"
    end

    test "renders registration form with pro plan when specified", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/register?plan=pro")

      assert html =~ "Create your account"
      assert html =~ "Selected plan:"
      assert html =~ "Pro"
    end

    test "defaults to free plan for invalid plan parameter", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/register?plan=invalid")

      assert html =~ "Create your account"
      # Should not show plan badge for free plan
      refute html =~ "Selected plan:"
    end

    test "redirects authenticated user", %{conn: conn} do
      # User already gets a free subscription on registration via CreateFreeSubscription change
      user = generate(user())
      conn = log_in_user(conn, user)

      # live_no_user redirects to "/" not "/chat"
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/register")
    end
  end

  describe "form validation" do
    test "validates password confirmation mismatch", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/register")

      html =
        view
        |> form("#register-form",
          user: %{
            email: "test@example.com",
            password: "password123",
            password_confirmation: "different"
          }
        )
        |> render_change()

      assert html =~ "does not match"
    end

    test "validates password length", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/register")

      html =
        view
        |> form("#register-form",
          user: %{
            email: "test@example.com",
            password: "short",
            password_confirmation: "short"
          }
        )
        |> render_change()

      # Check for password length validation - actual message may vary
      assert html =~ "at least" or html =~ "length"
    end
  end

  describe "form submission" do
    test "triggers form action on valid registration data", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/register")

      view
      |> form("#register-form",
        user: %{
          name: "Jane Doe",
          email: unique_email(),
          password: "ValidPassword123!",
          password_confirmation: "ValidPassword123!",
          accepted_terms: "true",
          accepted_age_requirement: "true"
        }
      )
      |> render_submit()

      # After validation passes, trigger_action is set to true,
      # which causes the form to POST to the auth controller for actual creation
      html = render(view)
      assert html =~ "phx-trigger-action"
    end

    test "does not trigger action for missing name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/register")

      html =
        view
        |> form("#register-form",
          user: %{
            email: unique_email(),
            password: "ValidPassword123!",
            password_confirmation: "ValidPassword123!",
            accepted_terms: "true",
            accepted_age_requirement: "true"
          }
        )
        |> render_submit()

      # Should show error, not trigger action
      refute html =~ "phx-trigger-action"
    end

    test "does not trigger action for password mismatch", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/register")

      html =
        view
        |> form("#register-form",
          user: %{
            name: "Jane Doe",
            email: unique_email(),
            password: "ValidPassword123!",
            password_confirmation: "DifferentPassword!",
            accepted_terms: "true",
            accepted_age_requirement: "true"
          }
        )
        |> render_submit()

      refute html =~ "phx-trigger-action"
    end
  end

  describe "hidden plan field" do
    test "includes selected plan in hidden field", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/register?plan=starter")

      assert html =~ ~s(name="user[selected_plan_key]" value="starter")
    end

    test "includes free plan in hidden field by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/register")

      assert html =~ ~s(name="user[selected_plan_key]" value="free")
    end
  end
end
