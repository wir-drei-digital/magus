defmodule MagusWeb.Api.Plugs.ApiTokenAuthPlugTest do
  use MagusWeb.ConnCase, async: true

  import Magus.Generators

  alias MagusWeb.Api.Plugs.ApiTokenAuthPlug

  describe "call/2" do
    test "returns 401 when no Authorization header is present" do
      conn = build_conn() |> ApiTokenAuthPlug.call([])

      assert conn.status == 401
      assert conn.halted
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "missing_token"
    end

    test "returns 401 when scheme is not Bearer" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Basic abc123")
        |> ApiTokenAuthPlug.call([])

      assert conn.status == 401
      assert conn.halted
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "invalid_scheme"
    end

    test "accepts lowercase bearer scheme" do
      user = generate(user())
      {_token, plaintext} = api_token(actor: user, scope: :read)

      conn =
        build_conn()
        |> put_req_header("authorization", "bearer #{plaintext}")
        |> ApiTokenAuthPlug.call([])

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
    end

    test "returns 401 when token is unknown" do
      conn =
        build_conn()
        |> put_req_header(
          "authorization",
          "Bearer mgs_pat_does_not_exist_xxxxxxxxxxxxxxxxxxxxxx"
        )
        |> ApiTokenAuthPlug.call([])

      assert conn.status == 401
      assert conn.halted
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "invalid_token"
    end

    test "returns 401 when token is revoked" do
      user = generate(user())
      {token, plaintext} = api_token(actor: user)
      {:ok, _} = Magus.Accounts.revoke_api_token(token, actor: user)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{plaintext}")
        |> ApiTokenAuthPlug.call([])

      assert conn.status == 401
      assert conn.halted
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "invalid_token"
    end

    test "returns 401 when token is expired" do
      user = generate(user())

      past = DateTime.utc_now() |> DateTime.add(-3600, :second)
      {_token, plaintext} = api_token(actor: user, expires_at: past)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{plaintext}")
        |> ApiTokenAuthPlug.call([])

      assert conn.status == 401
      assert conn.halted
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "invalid_token"
    end

    test "assigns current_user and current_token for a valid token" do
      user = generate(user())
      {token, plaintext} = api_token(actor: user, scope: :write)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{plaintext}")
        |> ApiTokenAuthPlug.call([])

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
      assert conn.assigns.current_token.id == token.id
      assert conn.assigns.current_token.scope == :write
    end
  end
end
