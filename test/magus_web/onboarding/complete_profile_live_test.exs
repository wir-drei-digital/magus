defmodule MagusWeb.OnboardingLive.CompleteProfileLiveTest do
  use MagusWeb.LiveViewCase, async: false

  import MagusWeb.LiveViewCase

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

  defp create_incomplete_user do
    # Create a user with accepted_terms: false to simulate magic link first sign-in
    user = generate(user())

    {:ok, user} =
      user
      |> Ash.Changeset.for_update(:update_settings, %{})
      |> Ash.Changeset.force_change_attribute(:accepted_terms, false)
      |> Ash.Changeset.force_change_attribute(:accepted_age_requirement, false)
      |> Ash.update(authorize?: false)

    user
  end

  describe "mount" do
    test "redirects unauthenticated user to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/complete-profile")
    end

    test "renders profile form for user with incomplete profile", %{conn: conn} do
      user = create_incomplete_user()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/complete-profile")

      assert html =~ "Complete Your Profile"
      assert html =~ "Name"
      assert html =~ "Username"
      assert html =~ "I accept the"
      assert html =~ "Terms of Service"
      assert html =~ "I confirm that I am at least 16 years old"
      assert html =~ "Continue"
    end

    test "redirects to chat if profile is already complete", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)

      # push_navigate produces a live_redirect
      assert {:error, {:live_redirect, %{to: "/next"}}} = live(conn, ~p"/complete-profile")
    end
  end

  describe "form validation" do
    test "validates form on change", %{conn: conn} do
      user = create_incomplete_user()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/complete-profile")

      html =
        view
        |> form("#complete-profile-form",
          user: %{name: "Jane Doe"}
        )
        |> render_change()

      assert html =~ "Jane Doe"
    end
  end

  describe "form submission" do
    test "completes profile with valid data", %{conn: conn} do
      user = create_incomplete_user()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/complete-profile")

      view
      |> form("#complete-profile-form",
        user: %{
          name: "Jane Doe",
          display_name: "janedoe",
          accepted_terms: "true",
          accepted_age_requirement: "true"
        }
      )
      |> render_submit()

      # push_navigate produces a live_redirect
      assert_redirect(view, "/next")
    end

    test "completes profile without display_name", %{conn: conn} do
      user = create_incomplete_user()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/complete-profile")

      view
      |> form("#complete-profile-form",
        user: %{
          name: "Jane Doe",
          accepted_terms: "true",
          accepted_age_requirement: "true"
        }
      )
      |> render_submit()

      assert_redirect(view, "/next")
    end

    test "shows errors when terms not accepted", %{conn: conn} do
      user = create_incomplete_user()
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/complete-profile")

      # Omit checkboxes entirely (browsers don't send unchecked checkboxes)
      html =
        view
        |> form("#complete-profile-form",
          user: %{name: "Jane Doe"}
        )
        |> render_submit()

      # Should stay on the page, not redirect
      assert html =~ "Complete Your Profile"
    end
  end

  describe "redirect guard" do
    test "live_user_required redirects incomplete profile to complete-profile", %{conn: conn} do
      user = create_incomplete_user()
      conn = log_in_user(conn, user)

      # Trying to access a page with :live_user_required should redirect
      assert {:error, {:redirect, %{to: "/complete-profile"}}} = live(conn, ~p"/chat")
    end
  end
end
