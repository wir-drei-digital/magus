defmodule MagusWeb.RootControllerTest do
  @moduledoc """
  The open-core root `/` sends authenticated users to the SPA (the primary UI)
  and anonymous users to sign-in. This route is owned by the composing router
  (`MagusWeb.Router`), not the `core_routes/0` macro, so the commercial edition
  (`magus_cloud`) can serve a marketing landing at `/` instead. This test pins
  the open-core behaviour across that seam.
  """
  use MagusWeb.ConnCase, async: true

  test "GET / sends authenticated users to the SPA", %{conn: conn} do
    user = Magus.Generators.generate(Magus.Generators.user())

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)
      |> get(~p"/")

    assert redirected_to(conn) == "/next"
  end

  test "GET / sends anonymous users to sign-in", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/sign-in"
  end
end
