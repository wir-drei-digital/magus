defmodule MagusWeb.Api.Plugs.ApiAuthPlugTest do
  use MagusWeb.ConnCase, async: true

  alias MagusWeb.Api.Plugs.ApiAuthPlug

  describe "call/2" do
    test "returns 401 when no authorization header" do
      conn =
        build_conn()
        |> ApiAuthPlug.call([])

      assert conn.status == 401
      assert conn.halted
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "invalid_api_key"
    end

    test "returns 401 when authorization header is malformed" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Basic abc123")
        |> ApiAuthPlug.call([])

      assert conn.status == 401
      assert conn.halted
    end

    test "returns 401 when API key not found" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer magus_sk_nonexistent")
        |> ApiAuthPlug.call([])

      assert conn.status == 401
      assert conn.halted
    end
  end
end
