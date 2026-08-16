defmodule MagusWeb.Plugs.CaptureClientIP do
  @moduledoc "Stores the resolved client IP in the session for LiveViews."
  @behaviour Plug

  alias MagusWeb.ClientIP

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Plug.Conn.put_session(
      conn,
      ClientIP.session_key(),
      ClientIP.to_string(ClientIP.from_conn(conn))
    )
  end
end
