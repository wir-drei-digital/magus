defmodule MagusWeb.E2E.SearchHistoryTest do
  @moduledoc """
  Browser-based E2E tests for the search and conversation history pages.

  Verifies that both pages render correctly, display existing conversations,
  and support searching. No LLM calls needed -- these are page interaction tests.
  """
  use MagusWeb.PlaywrightCase

  @moduletag :e2e

  # ------------------------------------------------------------------
  # Conversation History
  # ------------------------------------------------------------------

  describe "conversation history" do
    test "history page renders with heading and search input", %{conn: conn} do
      user = generate(user()) |> confirm_user()

      conn
      |> authenticate(user)
      |> visit(~p"/history")
      |> assert_has(".phx-connected")
      |> assert_has("h1", text: "Conversation History")
      |> assert_has("input[name='query']")
      |> assert_has("body", text: "Browse and search your past conversations")
    end

    test "history page shows existing conversations", %{conn: conn} do
      user = generate(user()) |> confirm_user()
      _conv1 = generate(conversation(actor: user, title: "Alpha Planning Session"))
      _conv2 = generate(conversation(actor: user, title: "Beta Review Meeting"))

      conn
      |> authenticate(user)
      |> visit(~p"/history")
      |> assert_has(".phx-connected")
      |> assert_has("body", text: "Alpha Planning Session")
      |> assert_has("body", text: "Beta Review Meeting")
      |> assert_has("body", text: "2 conversations")
    end

    test "history page shows empty state when user has no conversations", %{conn: conn} do
      user = generate(user()) |> confirm_user()

      conn
      |> authenticate(user)
      |> visit(~p"/history")
      |> assert_has(".phx-connected")
      |> assert_has("body", text: "No conversations yet")
    end

    test "history search filters conversations by title", %{conn: conn} do
      user = generate(user()) |> confirm_user()
      _conv1 = generate(conversation(actor: user, title: "Quantum Physics Discussion"))
      _conv2 = generate(conversation(actor: user, title: "Grocery Shopping List"))

      conn
      |> authenticate(user)
      |> visit(~p"/history")
      |> assert_has(".phx-connected")
      |> assert_has("body", text: "Quantum Physics Discussion")
      |> assert_has("body", text: "Grocery Shopping List")
      |> assert_has("body", text: "2 conversations")
      |> fill_in("Search conversations", with: "Quantum")
      |> assert_has("body", text: "1 conversation", timeout: 10_000)
      |> assert_has("body", text: "Quantum Physics Discussion")
    end
  end

  # ------------------------------------------------------------------
  # Search
  # ------------------------------------------------------------------

  describe "search page" do
    test "search page renders with heading and input", %{conn: conn} do
      user = generate(user()) |> confirm_user()

      conn
      |> authenticate(user)
      |> visit(~p"/search")
      |> assert_has(".phx-connected")
      |> assert_has("h1", text: "Search")
      |> assert_has("input[name='query']")
      |> assert_has("body", text: "Search across messages, conversations, prompts, and files")
    end

    test "search page shows empty state before searching", %{conn: conn} do
      user = generate(user()) |> confirm_user()

      conn
      |> authenticate(user)
      |> visit(~p"/search")
      |> assert_has(".phx-connected")
      |> assert_has("body", text: "Start typing to search across all your content")
    end

    test "search page shows type filter buttons", %{conn: conn} do
      user = generate(user()) |> confirm_user()

      conn
      |> authenticate(user)
      |> visit(~p"/search")
      |> assert_has(".phx-connected")
      |> assert_has("button", text: "Messages")
      |> assert_has("button", text: "Conversations")
      |> assert_has("button", text: "Prompts")
      |> assert_has("button", text: "Files")
    end

    test "search finds conversations by title", %{conn: conn} do
      user = generate(user()) |> confirm_user()
      _conv = generate(conversation(actor: user, title: "Unique Xylophone Research"))

      conn
      |> authenticate(user)
      |> visit(~p"/search")
      |> assert_has(".phx-connected")
      |> fill_in("Search", with: "Xylophone Research")
      |> assert_has("body", text: "Unique Xylophone Research", timeout: 5_000)
    end

    test "search shows no results message for unmatched query", %{conn: conn} do
      user = generate(user()) |> confirm_user()

      conn
      |> authenticate(user)
      |> visit(~p"/search?q=zzzznonexistent99999")
      |> assert_has(".phx-connected")
      |> assert_has("body", text: "No results found", timeout: 5_000)
    end
  end
end
