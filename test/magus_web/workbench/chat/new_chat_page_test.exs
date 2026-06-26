defmodule MagusWeb.ChatLive.NewChatPageTest do
  @moduledoc """
  Integration tests for the new chat page onboarding experience.

  Tests verify:
  - First-time users see welcome heading and all feature cards
  - Returning users see only undiscovered feature cards
  - Fully onboarded users see a clean state with no feature cards
  - Announcement rendering and dismissal
  """
  use MagusWeb.LiveViewCase, async: false

  import MagusWeb.LiveViewCase

  # ChatLive routes are taken over by WorkbenchLive when the workbench flag is on.
  # TODO: remove in Phase 7 when the flag is retired and ChatLive is deleted.
  @moduletag :skip

  @onboarding_features Magus.FeatureUsage.onboarding_feature_keys()

  # ---------------------------------------------------------------------------
  # Setup helpers
  # ---------------------------------------------------------------------------

  defp create_confirmed_user do
    user = generate(user())

    user
    |> Ash.Changeset.for_update(:update_profile, %{})
    |> Ash.Changeset.force_change_attribute(:confirmed_at, DateTime.utc_now())
    |> Ash.update!(authorize?: false)
  end

  defp mount_chat(conn) do
    live(conn, ~p"/chat", on_error: :warn)
  end

  # ---------------------------------------------------------------------------
  # First-time user (no features discovered)
  # ---------------------------------------------------------------------------

  describe "first-time user" do
    setup %{conn: conn} do
      user = create_confirmed_user()
      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "sees MAGUS branding and subtitle", %{conn: conn} do
      {:ok, _view, html} = mount_chat(conn)

      assert html =~ "What would you like to explore?"
    end

    test "sees all four feature cards", %{conn: conn} do
      {:ok, _view, html} = mount_chat(conn)

      assert html =~ "Create a reusable prompt"
      assert html =~ "Set a reminder"
      assert html =~ "Search the web"
      assert html =~ "Try draft mode"
    end

    test "does not show returning user subtitle", %{conn: conn} do
      {:ok, _view, html} = mount_chat(conn)

      refute html =~ "What&#39;s on your mind?"
    end

    test "does not show 'Haven&#39;t tried yet' section header", %{conn: conn} do
      {:ok, _view, html} = mount_chat(conn)

      refute html =~ "Haven"
    end
  end

  # ---------------------------------------------------------------------------
  # Returning user (some features discovered)
  # ---------------------------------------------------------------------------

  describe "returning user with some features discovered" do
    setup %{conn: conn} do
      user = create_confirmed_user()

      # Mark two features as discovered
      Magus.FeatureUsage.track(user.id, "prompts", "create")
      Magus.FeatureUsage.track(user.id, "web_search", "execute")

      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "sees returning user subtitle instead of first-time subtitle", %{conn: conn} do
      {:ok, _view, html} = mount_chat(conn)

      assert html =~ "What&#39;s on your mind?"
      refute html =~ "What would you like to explore?"
    end

    test "shows only undiscovered feature cards", %{conn: conn} do
      {:ok, _view, html} = mount_chat(conn)

      # Discovered features should NOT appear (use card descriptions to avoid
      # false matches from slash commands in the chat input action menu)
      refute html =~ "Save instructions you use often"
      refute html =~ "Find current information online"

      # Undiscovered features SHOULD appear
      assert html =~ "I&#39;ll follow up on schedule"
      assert html =~ "Write and iterate together"
    end
  end

  # ---------------------------------------------------------------------------
  # Fully onboarded user (all features discovered)
  # ---------------------------------------------------------------------------

  describe "fully onboarded user" do
    setup %{conn: conn} do
      user = create_confirmed_user()

      # Mark ALL onboarding features as discovered
      for feature <- @onboarding_features do
        Magus.FeatureUsage.track(user.id, feature, "use")
      end

      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user}
    end

    test "sees returning user subtitle", %{conn: conn} do
      {:ok, _view, html} = mount_chat(conn)

      assert html =~ "What&#39;s on your mind?"
    end

    test "does not show any feature cards", %{conn: conn} do
      {:ok, _view, html} = mount_chat(conn)

      # Use card descriptions to avoid false matches from slash commands
      refute html =~ "Save instructions you use often"
      refute html =~ "I&#39;ll follow up on schedule"
      refute html =~ "Find current information online"
      refute html =~ "Write and iterate together"
    end

    test "does not show first-time subtitle", %{conn: conn} do
      {:ok, _view, html} = mount_chat(conn)

      refute html =~ "What would you like to explore?"
    end
  end

  # ---------------------------------------------------------------------------
  # Announcements
  # ---------------------------------------------------------------------------

  describe "announcements" do
    setup %{conn: conn} do
      user = create_confirmed_user()

      # Mark all features as discovered so we get the "returning" view
      for feature <- @onboarding_features do
        Magus.FeatureUsage.track(user.id, feature, "use")
      end

      # Create an active announcement
      {:ok, announcement} =
        Magus.FeatureUsage.Announcement
        |> Ash.Changeset.for_create(:create, %{
          key: "test-announcement",
          title: %{"en" => "New Feature Available", "de" => "Neues Feature verfügbar"},
          description: %{
            "en" => "Check out this great new feature",
            "de" => "Schau dir dieses tolle neue Feature an"
          },
          icon: "🎉",
          action_type: "navigate",
          action_payload: "/chat?topic=new_feature"
        })
        |> Ash.create!(authorize?: false)
        |> then(&{:ok, &1})

      conn = log_in_user(conn, user)
      {:ok, conn: conn, user: user, announcement: announcement}
    end

    test "renders unseen announcements", %{conn: conn} do
      {:ok, _view, html} = mount_chat(conn)

      assert html =~ "New Feature Available"
      assert html =~ "Check out this great new feature"
    end

    test "announcement has NEW badge", %{conn: conn} do
      {:ok, _view, html} = mount_chat(conn)

      assert html =~ "NEW"
    end

    test "announcement has Learn more link", %{conn: conn} do
      {:ok, _view, html} = mount_chat(conn)

      assert html =~ "Learn more"
    end

    test "dismissing an announcement removes it from view", %{conn: conn} do
      {:ok, view, html} = mount_chat(conn)

      assert html =~ "New Feature Available"

      # Click the dismiss button
      html = render_click(view, "dismiss_announcement", %{"key" => "test-announcement"})

      refute html =~ "New Feature Available"
    end

    test "dismissed announcement stays dismissed on re-mount", %{conn: conn} do
      {:ok, view, _html} = mount_chat(conn)

      # Dismiss the announcement
      render_click(view, "dismiss_announcement", %{"key" => "test-announcement"})

      # Re-mount the page
      {:ok, _view, html} = mount_chat(conn)

      refute html =~ "New Feature Available"
    end
  end
end
