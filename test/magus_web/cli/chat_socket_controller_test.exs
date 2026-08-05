defmodule MagusWeb.Cli.ChatSocketControllerTest do
  use MagusWeb.ConnCase, async: true
  import Magus.Generators

  test "rejects a missing token with 401", %{conn: conn} do
    conn = get(conn, "/cli/chat")
    assert json_response(conn, 401)["error"]["code"] == "missing_token"
  end

  test "rejects an invalid token with 401", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer not-a-real-token")
      |> get("/cli/chat")

    assert json_response(conn, 401)["error"]["code"] == "invalid_token"
  end

  test "rejects a read-scoped token with 403", %{conn: conn} do
    # RequireTokenScope gates on HTTP method, which is meaningless for a GET
    # that upgrades into a full-duplex channel: the bridge drives turns and
    # local file reads, so it must demand :write explicitly.
    user = generate(user())
    {_token, plaintext} = api_token(actor: user, scope: :read)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{plaintext}")
      |> get("/cli/chat")

    assert json_response(conn, 403)["error"]["code"] == "insufficient_scope"
  end

  test "a valid write token passes auth and the connection is upgraded", %{conn: conn} do
    user = generate(user())
    {_token, plaintext} = api_token(actor: user, scope: :write)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{plaintext}")
      # WebSockAdapter.upgrade/4 validates the request is a real WS handshake
      # (RFC6455 §4.2) before upgrading, so supply the mandatory headers.
      |> put_req_header("connection", "upgrade")
      |> put_req_header("upgrade", "websocket")
      |> put_req_header("sec-websocket-key", Base.encode64("0123456789abcdef"))
      |> put_req_header("sec-websocket-version", "13")

    # Plug refuses `put_req_header("host", ...)` and Plug.Test won't derive one
    # from conn.host, but the WS validator requires it — inject it for the test.
    conn = %{conn | req_headers: [{"host", "localhost"} | conn.req_headers]}

    conn = get(conn, "/cli/chat")

    # WebSockAdapter.upgrade/4 marks the conn upgraded via upgrade_adapter/3
    # rather than sending a response body; assert it passed auth and upgraded.
    refute conn.status == 401
    assert conn.state == :upgraded

    # The Plug.Test adapter forwards the upgrade to the owner process; confirm the
    # ChatSocket handler was chosen, seeded with the authed user, and capped.
    assert_received {_ref, :upgrade, {:websocket, {MagusWeb.Cli.ChatSocket, state, opts}}}
    assert state.user.id == user.id
    # A frame-size cap must be set: the Bandit default is unlimited buffering.
    assert opts[:max_frame_size]
  end
end
