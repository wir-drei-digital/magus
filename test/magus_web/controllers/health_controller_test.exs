defmodule MagusWeb.HealthControllerTest do
  use MagusWeb.ConnCase, async: false

  test "GET /health returns 200 with status, falkordb, checked_at", %{conn: conn} do
    conn = get(conn, ~p"/health")
    body = json_response(conn, 200)

    assert body["status"] == "ok"
    # FalkorDB may or may not be available in CI; both states are acceptable.
    # The endpoint itself must succeed regardless.
    assert body["falkordb"] in ["ok", "unavailable"]
    assert is_binary(body["checked_at"])
    # ISO 8601 sanity check
    assert {:ok, _, _} = DateTime.from_iso8601(body["checked_at"])
  end

  test "GET /health requires no authentication", %{conn: conn} do
    # No auth headers/session; should still succeed.
    conn = get(conn, ~p"/health")
    assert json_response(conn, 200)["status"] == "ok"
  end
end
