defmodule MagusWeb.Cli.ChatSocketController do
  use MagusWeb, :controller

  # ApiTokenAuthPlug (on the :cli_socket pipeline) has already authenticated and
  # assigned :current_user / :current_token, or halted with 401.
  #
  # Scope is enforced here rather than via RequireTokenScope: that plug gates on
  # HTTP method, which is meaningless for a GET that upgrades into a full-duplex
  # channel. The bridge drives turns and local file reads, so it demands :write.
  def upgrade(conn, _params) do
    if conn.assigns.current_token.scope == :write do
      conn
      |> WebSockAdapter.upgrade(MagusWeb.Cli.ChatSocket, %{user: conn.assigns.current_user},
        timeout: 60_000,
        max_frame_size: 1_000_000
      )
      |> halt()
    else
      body =
        Jason.encode!(%{
          "error" => %{
            "code" => "insufficient_scope",
            "message" => "This token has scope :read but the CLI chat bridge requires :write"
          }
        })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, body)
      |> halt()
    end
  end
end
