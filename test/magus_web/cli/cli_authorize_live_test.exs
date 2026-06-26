defmodule MagusWeb.Cli.CliAuthorizeLiveTest do
  use MagusWeb.LiveViewCase, async: false

  import MagusWeb.LiveViewCase

  setup %{conn: conn} do
    user = generate(user())
    %{conn: log_in_user(conn, user), user: user}
  end

  test "redirects to /sign-in when not authenticated" do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.get("/cli/authorize?callback=http://127.0.0.1:5555&state=abc")

    assert Phoenix.ConnTest.redirected_to(conn) =~ "/sign-in"
  end

  test "rejects non-loopback callbacks", %{conn: conn} do
    {:error, {:live_redirect, %{to: path}}} =
      live(conn, "/cli/authorize?callback=https://attacker.example.com&state=abc")

    assert path == "/"
  end

  test "rejects callback whose host embeds loopback as a prefix", %{conn: conn} do
    {:error, {:live_redirect, %{to: "/"}}} =
      live(conn, "/cli/authorize?callback=http://127.0.0.1.evil.com:5555&state=abc")
  end

  test "renders the authorize form with workspace and scope options", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/cli/authorize?callback=http://127.0.0.1:5555&state=abc")

    assert html =~ "Magus CLI wants access"
    assert html =~ "Personal"
    assert html =~ "Read"
  end

  test "on approve, creates token and redirects to callback with token and state", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} =
      live(conn, "/cli/authorize?callback=http://127.0.0.1:5555&state=abc")

    {:error, {:redirect, %{to: external}}} =
      view
      |> form("#cli-authorize-form", %{
        "token" => %{
          "name" => "Claude Code on laptop",
          "scope" => "write",
          "workspace_id" => ""
        }
      })
      |> render_submit()

    assert external =~ "http://127.0.0.1:5555"
    assert external =~ "state=abc"
    assert external =~ "token=mgs_pat_"

    {:ok, tokens} = Magus.Accounts.list_api_tokens(actor: user)
    cli_tokens = Enum.filter(tokens, &(&1.created_via == :cli_login))
    assert length(cli_tokens) == 1
    [token] = cli_tokens
    assert token.name == "Claude Code on laptop"
    assert token.scope == :write
  end
end
