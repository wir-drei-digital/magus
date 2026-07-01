defmodule MagusWeb.OnboardingLive.CreateOrganizationLiveTest do
  @moduledoc """
  Tests for the optional post-registration "create an organization" step at
  `/onboarding/organization`.

  - Renders a name + slug form for an authenticated user without an org.
  - Submitting creates an org owned by the actor and navigates to the org
    billing settings.
  - A user who already belongs to an org is redirected to the members tab on
    mount (no duplicate-org creation path).
  - "Skip for now" links back to the app root.
  """
  use MagusWeb.LiveViewCase, async: false

  import MagusWeb.LiveViewCase

  alias Magus.Organizations

  describe "mount" do
    test "redirects unauthenticated user to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} =
               live(conn, ~p"/onboarding/organization")
    end

    test "renders the create-organization form for a user without an org", %{conn: conn} do
      user = generate(user())
      conn = log_in_user(conn, user)

      {:ok, view, html} = live(conn, ~p"/onboarding/organization")

      assert html =~ "organization"
      assert has_element?(view, "#create-organization-form")
      assert has_element?(view, "input[name=\"organization[name]\"]")
      assert has_element?(view, "input[name=\"organization[slug]\"]")
      # Skip escape hatch back to the app root.
      assert has_element?(view, ~s(a[href="/"]))
      assert html =~ "Skip"
    end

    test "redirects a user who already has an org to the members tab", %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, _org} =
        Organizations.create_organization(
          %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
          actor: user
        )

      conn = log_in_user(conn, user)

      assert {:error, {:live_redirect, %{to: "/settings/organization/members"}}} =
               live(conn, ~p"/onboarding/organization")
    end
  end

  describe "form submission" do
    test "creates an org for the actor and navigates to billing", %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/onboarding/organization")

      view
      |> form("#create-organization-form",
        organization: %{name: "Wonka Industries", slug: "wonka-industries"}
      )
      |> render_submit()

      assert_redirect(view, "/settings/organization/billing")

      assert {:ok, [membership]} = Organizations.my_organization(actor: user)
      assert membership.organization.name == "Wonka Industries"
      assert membership.organization.slug == "wonka-industries"
      assert membership.role == :owner
    end

    test "auto-slugifies the name when the slug is left blank", %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/onboarding/organization")

      # Mirror the browser: typing the name auto-fills the slug on change.
      view
      |> form("#create-organization-form", organization: %{name: "Wonka Industries", slug: ""})
      |> render_change()

      view
      |> form("#create-organization-form", organization: %{name: "Wonka Industries", slug: ""})
      |> render_submit()

      assert_redirect(view, "/settings/organization/billing")

      assert {:ok, [membership]} = Organizations.my_organization(actor: user)
      assert membership.organization.slug == "wonka-industries"
    end

    test "re-renders the form with errors on invalid input", %{conn: conn} do
      user = generate(user())
      ensure_workspace_plan(user)
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/onboarding/organization")

      html =
        view
        |> form("#create-organization-form", organization: %{name: "", slug: ""})
        |> render_submit()

      # Stays on the page (no redirect) rather than creating an org.
      assert html =~ "organization"
      assert {:ok, []} = Organizations.my_organization(actor: user)
    end
  end
end
