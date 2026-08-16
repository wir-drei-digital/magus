defmodule MagusWeb.Plugs.CaptureClientIPTest do
  @moduledoc """
  Covers `MagusWeb.Plugs.CaptureClientIP` both through the real browser
  pipeline (the session gets the resolved IP) and directly at the plug
  level (write-if-changed: an already-correct session value must not be
  re-written, since `put_session/3` marks the session dirty and forces a
  `Set-Cookie` on every response — which would defeat CDN caching of
  anonymous pages).
  """
  use MagusWeb.ConnCase, async: false

  alias MagusWeb.Plugs.CaptureClientIP

  test "a GET through the browser pipeline sets client_ip in the session", %{conn: conn} do
    conn = get(conn, ~p"/sign-in")
    assert get_session(conn, "client_ip") == "127.0.0.1"
  end

  describe "write-if-changed" do
    test "writes the session when there is no value yet" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{})
        |> Map.put(:remote_ip, {127, 0, 0, 1})

      result = CaptureClientIP.call(conn, [])

      assert get_session(result, "client_ip") == "127.0.0.1"
      assert result.private[:plug_session_info] == :write
    end

    test "leaves the session/conn untouched when the value already matches" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> Plug.Test.init_test_session(%{"client_ip" => "127.0.0.1"})
        # init_test_session itself writes via put_session; reset the dirty
        # marker so we can tell whether OUR plug call writes again.
        |> Plug.Conn.put_private(:plug_session_info, nil)

      result = CaptureClientIP.call(conn, [])

      assert get_session(result, "client_ip") == "127.0.0.1"
      refute result.private[:plug_session_info] == :write
    end
  end
end
