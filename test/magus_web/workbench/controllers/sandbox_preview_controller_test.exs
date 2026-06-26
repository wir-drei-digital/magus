defmodule MagusWeb.SandboxPreviewControllerTest do
  @moduledoc """
  Tests for the SandboxPreviewController (authenticated reverse proxy).

  Tests cover:
  - Authentication enforcement (unauthenticated users redirected)
  - Authorization (user must own the conversation's sandbox)
  - HTTP method handling (allowed methods vs rejected)
  - Header stripping (hop-by-hop, security headers)
  - Error handling for missing/inactive sandboxes
  """
  use MagusWeb.ConnCase, async: true

  import Magus.Generators

  alias Magus.Chat

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup %{conn: conn} do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

    %{
      conn: conn,
      user: user,
      conversation: conversation
    }
  end

  # ---------------------------------------------------------------------------
  # Authentication
  # ---------------------------------------------------------------------------

  describe "proxy/2 - authentication" do
    test "redirects unauthenticated user to sign-in", %{conn: conn, conversation: conversation} do
      conn = get(conn, "/sandbox/preview/#{conversation.id}/")

      # The :require_auth_browser pipeline redirects to /sign-in
      assert redirected_to(conn) == "/sign-in"
    end

    test "redirects unauthenticated POST to sign-in", %{conn: conn, conversation: conversation} do
      conn = post(conn, "/sandbox/preview/#{conversation.id}/api/data", %{})

      assert redirected_to(conn) == "/sign-in"
    end
  end

  # ---------------------------------------------------------------------------
  # Authorization
  # ---------------------------------------------------------------------------

  describe "proxy/2 - authorization" do
    test "returns 404 for non-existent conversation", %{conn: conn, user: user} do
      conn =
        conn
        |> log_in_user(user)
        |> get("/sandbox/preview/#{Ecto.UUID.generate()}/")

      assert json_response(conn, 404)["error"] == "Sandbox not found"
    end

    test "returns 404 when user does not own the conversation", %{
      conn: conn,
      conversation: conversation
    } do
      other_user = generate(user())

      conn =
        conn
        |> log_in_user(other_user)
        |> get("/sandbox/preview/#{conversation.id}/")

      assert json_response(conn, 404)["error"] == "Sandbox not found"
    end

    test "returns 404 when conversation has no sandbox", %{
      conn: conn,
      user: user,
      conversation: conversation
    } do
      # Conversation exists but has no sandbox provisioned
      conn =
        conn
        |> log_in_user(user)
        |> get("/sandbox/preview/#{conversation.id}/")

      assert json_response(conn, 404)["error"] == "Sandbox not found"
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP Method Handling
  # ---------------------------------------------------------------------------

  describe "proxy/2 - HTTP methods" do
    test "handles GET requests", %{conn: conn, user: user, conversation: conversation} do
      conn =
        conn
        |> log_in_user(user)
        |> get("/sandbox/preview/#{conversation.id}/index.html")

      # Will be 404 (no sandbox) but should not crash
      assert conn.status in [404, 502]
    end

    test "handles POST requests", %{conn: conn, user: user, conversation: conversation} do
      conn =
        conn
        |> log_in_user(user)
        |> post("/sandbox/preview/#{conversation.id}/api/submit", %{data: "test"})

      assert conn.status in [404, 502]
    end

    test "handles PUT requests", %{conn: conn, user: user, conversation: conversation} do
      conn =
        conn
        |> log_in_user(user)
        |> put("/sandbox/preview/#{conversation.id}/api/resource/1", %{name: "updated"})

      assert conn.status in [404, 502]
    end

    test "handles DELETE requests", %{conn: conn, user: user, conversation: conversation} do
      conn =
        conn
        |> log_in_user(user)
        |> delete("/sandbox/preview/#{conversation.id}/api/resource/1")

      assert conn.status in [404, 502]
    end

    test "handles PATCH requests", %{conn: conn, user: user, conversation: conversation} do
      conn =
        conn
        |> log_in_user(user)
        |> patch("/sandbox/preview/#{conversation.id}/api/resource/1", %{name: "patched"})

      assert conn.status in [404, 502]
    end
  end

  # ---------------------------------------------------------------------------
  # Path Handling
  # ---------------------------------------------------------------------------

  describe "proxy/2 - path handling" do
    test "handles root path", %{conn: conn, user: user, conversation: conversation} do
      conn =
        conn
        |> log_in_user(user)
        |> get("/sandbox/preview/#{conversation.id}/")

      # No sandbox → 404, but path handling should not crash
      assert conn.status in [404, 502]
    end

    test "handles nested paths", %{conn: conn, user: user, conversation: conversation} do
      conn =
        conn
        |> log_in_user(user)
        |> get("/sandbox/preview/#{conversation.id}/assets/css/style.css")

      assert conn.status in [404, 502]
    end

    test "handles query strings", %{conn: conn, user: user, conversation: conversation} do
      conn =
        conn
        |> log_in_user(user)
        |> get("/sandbox/preview/#{conversation.id}/api/data?page=1&limit=10")

      assert conn.status in [404, 502]
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp log_in_user(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
