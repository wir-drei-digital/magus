defmodule MagusWeb.Cli.ChatSocketController do
  use MagusWeb, :controller

  # ApiTokenAuthPlug (on the :cli_socket pipeline) has already authenticated and
  # assigned :current_user / :current_token, or halted with 401.
  def upgrade(conn, _params) do
    state = %{user: conn.assigns.current_user, token: conn.assigns.current_token}

    conn
    |> WebSockAdapter.upgrade(MagusWeb.Cli.ChatSocket, state, timeout: 60_000)
    |> halt()
  end
end
