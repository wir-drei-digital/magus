defmodule MagusWeb.Content.InstallScriptControllerTest do
  use MagusWeb.ConnCase, async: true

  test "GET /install.sh redirects to the CLI repo's main install.sh", %{conn: conn} do
    conn = get(conn, ~p"/install.sh")

    assert response(conn, 302)
    location = conn |> get_resp_header("location") |> List.first()
    assert location =~ "wir-drei-digital/magus-cli"
    assert location =~ "install.sh"
  end

  test "GET /install.sh sets a short cache header", %{conn: conn} do
    conn = get(conn, ~p"/install.sh")

    cache = conn |> get_resp_header("cache-control") |> List.first()
    assert cache =~ "max-age="
  end
end
