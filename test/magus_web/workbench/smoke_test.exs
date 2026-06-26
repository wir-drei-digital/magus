defmodule MagusWeb.SmokeTest do
  @moduledoc """
  Simple smoke tests to verify that key pages load without 500 errors.

  These tests are not meant to test any specific functionality, just to ensure
  the pages render successfully and don't crash on mount.
  """
  use MagusWeb.LiveViewCase, async: false

  import MagusWeb.LiveViewCase

  alias Magus.Usage

  # Helper to create a user with a subscription
  defp setup_user_with_subscription do
    user = generate(user())

    {:ok, plan} =
      Usage.create_usage_plan(
        %{
          key: "test-plan-#{System.unique_integer([:positive])}",
          name: "Test Plan",
          storage_bytes: 1_000_000_000,
          max_upload_bytes: 100_000_000,
          is_active: true
        },
        authorize?: false
      )

    {:ok, _subscription} =
      Usage.create_user_subscription(
        %{user_id: user.id, usage_plan_id: plan.id, status: :active},
        authorize?: false
      )

    user
  end

  describe "public pages (no auth required)" do
    test "prompts page loads", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/prompts")

      assert html =~ "Prompts"
    end

    test "models page loads", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/models")

      assert html =~ "Models"
    end
  end

  describe "authenticated pages" do
    test "settings page loads", %{conn: conn} do
      user = setup_user_with_subscription()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/settings")

      assert html =~ "Settings"
    end

    test "subscription page loads", %{conn: conn} do
      user = setup_user_with_subscription()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/settings/subscription")

      assert html =~ "Subscription"
    end

    test "jobs page loads", %{conn: conn} do
      user = setup_user_with_subscription()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/jobs")

      assert html =~ "Scheduled Jobs"
    end

    @tag :skip
    # TODO: Fix stream empty state ID issue in agents_live.ex
    test "agents dashboard loads", %{conn: conn} do
      user = setup_user_with_subscription()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "Agents Dashboard"
    end

    @tag :skip
    # TODO: Need to seed providers for this test to work
    test "integrations settings page loads", %{conn: conn} do
      user = setup_user_with_subscription()
      conn = log_in_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/settings/integrations")

      assert html =~ "Integrations"
    end
  end

  describe "auth redirects" do
    test "settings redirects unauthenticated user to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/settings")
    end

    test "subscription redirects unauthenticated user to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/settings/subscription")
    end

    test "jobs redirects unauthenticated user to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/jobs")
    end

    test "agents redirects unauthenticated user to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/agents")
    end

    test "integrations settings redirects unauthenticated user to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/settings/integrations")
    end
  end
end
