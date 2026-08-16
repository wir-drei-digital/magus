defmodule MagusWeb.ClientIPTest do
  use MagusWeb.ConnCase, async: false

  alias MagusWeb.ClientIP

  setup do
    original = Application.get_env(:magus, :client_ip_header)
    on_exit(fn -> Application.put_env(:magus, :client_ip_header, original) end)
    :ok
  end

  test "defaults to conn.remote_ip", %{conn: conn} do
    Application.put_env(:magus, :client_ip_header, nil)
    assert ClientIP.from_conn(conn) == conn.remote_ip
  end

  test "uses the configured header, first value, parsed", %{conn: conn} do
    Application.put_env(:magus, :client_ip_header, "fly-client-ip")
    conn = Plug.Conn.put_req_header(conn, "fly-client-ip", "203.0.113.7")
    assert ClientIP.from_conn(conn) == {203, 0, 113, 7}
  end

  test "malformed header falls back to remote_ip", %{conn: conn} do
    Application.put_env(:magus, :client_ip_header, "fly-client-ip")
    conn = Plug.Conn.put_req_header(conn, "fly-client-ip", "not-an-ip")
    assert ClientIP.from_conn(conn) == conn.remote_ip
  end

  test "to_string/from_session round-trip" do
    assert ClientIP.to_string({203, 0, 113, 7}) == "203.0.113.7"
    assert ClientIP.from_session(%{"client_ip" => "203.0.113.7"}) == {203, 0, 113, 7}
    assert ClientIP.from_session(%{}) == nil
  end
end
