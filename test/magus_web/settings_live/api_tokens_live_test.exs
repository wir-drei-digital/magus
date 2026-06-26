defmodule MagusWeb.SettingsLive.ApiTokensLiveTest do
  use MagusWeb.LiveViewCase, async: false

  import MagusWeb.LiveViewCase

  setup %{conn: conn} do
    user = generate(user())
    %{conn: log_in_user(conn, user), user: user}
  end

  test "redirects to /sign-in when not authenticated" do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.get("/settings/api-tokens")

    assert Phoenix.ConnTest.redirected_to(conn) =~ "/sign-in"
  end

  test "renders an empty state when the user has no tokens", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/settings/api-tokens")
    assert html =~ "No tokens yet"
    assert html =~ "Generate token"
  end

  test "lists existing tokens with name and scope", %{conn: conn, user: user} do
    {_t1, _} = api_token(actor: user, name: "CI", scope: :read)
    {_t2, _} = api_token(actor: user, name: "Claude Code", scope: :write)

    {:ok, _view, html} = live(conn, "/settings/api-tokens")

    assert html =~ "CI"
    assert html =~ "Claude Code"
    assert html =~ "read"
    assert html =~ "write"
  end

  test "create modal generates a new token and shows the plaintext once", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, "/settings/api-tokens")

    view |> element("button", "Generate token") |> render_click()
    assert render(view) =~ "New token"

    html =
      view
      |> form("#new-token-form", %{
        "token" => %{"name" => "Cursor", "scope" => "write", "workspace_id" => ""}
      })
      |> render_submit()

    assert html =~ "mgs_pat_"
    assert html =~ "Copy"

    {:ok, tokens} = Magus.Accounts.list_api_tokens(actor: user)
    assert Enum.any?(tokens, &(&1.name == "Cursor"))
  end

  test "revoke button removes the token from the list", %{conn: conn, user: user} do
    {token, _} = api_token(actor: user, name: "Doomed", scope: :read)

    {:ok, view, _html} = live(conn, "/settings/api-tokens")
    assert render(view) =~ "Doomed"

    view
    |> element("button[phx-value-id=\"#{token.id}\"]", "Revoke")
    |> render_click()

    refute render(view) =~ "Doomed"
  end

  test "revoking the last token re-shows the empty state", %{conn: conn, user: user} do
    {token, _} = api_token(actor: user, name: "Solo", scope: :read)

    {:ok, view, _html} = live(conn, "/settings/api-tokens")
    refute render(view) =~ "No tokens yet"

    view
    |> element("button[phx-value-id=\"#{token.id}\"]", "Revoke")
    |> render_click()

    assert render(view) =~ "No tokens yet"
  end

  test "cannot revoke another user's token", %{conn: conn, user: user} do
    other = generate(user())
    {their_token, _} = api_token(actor: other, name: "Theirs", scope: :read)
    {_mine, _} = api_token(actor: user, name: "Mine", scope: :read)

    {:ok, view, _html} = live(conn, "/settings/api-tokens")

    # The forged button does not appear in the rendered page, but a malicious
    # client could still POST the event manually. Confirm the LiveView
    # gracefully ignores the request and the other user's token survives.
    render_hook(view, "revoke_token", %{"id" => their_token.id})

    {:ok, [token]} = Magus.Accounts.list_api_tokens(actor: other)
    assert token.id == their_token.id
    assert is_nil(token.revoked_at)

    # Our own token is still listed.
    assert render(view) =~ "Mine"
  end
end
