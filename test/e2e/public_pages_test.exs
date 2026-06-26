defmodule MagusWeb.E2E.PublicPagesTest do
  @moduledoc """
  Browser-based E2E smoke tests for public pages.

  Verifies that all public-facing pages render without errors for both
  unauthenticated and authenticated visitors. No LLM calls are needed --
  these are purely page-load smoke tests.
  """
  use MagusWeb.PlaywrightCase

  @moduletag :e2e

  # ------------------------------------------------------------------
  # Public functional pages (prompt + model catalogs). Marketing/CMS
  # pages (home, help, legal) live in the commercial edition.
  # ------------------------------------------------------------------

  describe "unauthenticated - prompts library" do
    test "renders page heading and filter controls", %{conn: conn} do
      conn
      |> visit(~p"/prompts")
      |> assert_has("h1", text: "Prompts Library")
      |> assert_has("button", text: "Public")
    end
  end

  describe "unauthenticated - models page" do
    test "renders page heading and filter controls", %{conn: conn} do
      # Ensure at least one model exists so the page has content
      create_default_model()

      conn
      |> visit(~p"/models")
      |> assert_has("h1", text: "AI Models")
      |> assert_has("body", text: "Explore available models")
    end
  end

  # ------------------------------------------------------------------
  # Authenticated pages
  # ------------------------------------------------------------------

  describe "authenticated - prompts library" do
    test "shows user filter tabs when signed in", %{conn: conn} do
      user = generate(user()) |> confirm_user()

      conn
      |> authenticate(user)
      |> visit(~p"/prompts")
      |> assert_has("h1", text: "Prompts Library")
      |> assert_has("button", text: "All")
      |> assert_has("button", text: "My Prompts")
    end

    test "displays user's own prompt in the listing", %{conn: conn} do
      user = generate(user()) |> confirm_user()
      _prompt = generate(prompt(actor: user, name: "E2E Personal Prompt"))

      conn
      |> authenticate(user)
      |> visit(~p"/prompts")
      |> assert_has("body", text: "E2E Personal Prompt")
    end
  end
end
