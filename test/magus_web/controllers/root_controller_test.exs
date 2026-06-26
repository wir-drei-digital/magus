defmodule MagusWeb.RootControllerTest do
  @moduledoc """
  The open-core root `/` hands off to the workbench. This route is owned by the
  composing router (`MagusWeb.Router`), not the `core_routes/0` macro, so the
  commercial edition (`magus_cloud`) can serve a marketing landing at `/`
  instead. This test pins the open-core behaviour across that seam.
  """
  use MagusWeb.ConnCase, async: true

  test "GET / redirects to the workbench", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/chat"
  end
end
