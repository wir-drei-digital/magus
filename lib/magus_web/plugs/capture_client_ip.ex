defmodule MagusWeb.Plugs.CaptureClientIP do
  @moduledoc """
  Stores the resolved client IP in the session for LiveViews.

  Write-if-changed: `put_session/3` marks the session (and thus the response
  cookie) dirty even when the value is unchanged, which would defeat CDN
  caching of anonymous pages by forcing a `Set-Cookie` on every request. A
  session-holding user's IP is effectively stable across a session, so once
  it's written once we leave the conn untouched on subsequent requests.
  """
  @behaviour Plug

  alias MagusWeb.ClientIP

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    value = ClientIP.to_string(ClientIP.from_conn(conn))

    if Plug.Conn.get_session(conn, ClientIP.session_key()) == value do
      conn
    else
      Plug.Conn.put_session(conn, ClientIP.session_key(), value)
    end
  end
end
