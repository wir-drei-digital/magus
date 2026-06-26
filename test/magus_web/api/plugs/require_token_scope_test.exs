defmodule MagusWeb.Api.Plugs.RequireTokenScopeTest do
  use MagusWeb.ConnCase, async: true

  import Magus.Generators

  alias MagusWeb.Api.Plugs.RequireTokenScope

  setup do
    user = generate(user())
    {read_token, _} = api_token(actor: user, scope: :read)
    {write_token, _} = api_token(actor: user, scope: :write)
    %{user: user, read_token: read_token, write_token: write_token}
  end

  test "passes GET requests with read token", %{read_token: token} do
    conn =
      build_conn(:get, "/api/v2/brains")
      |> assign(:current_token, token)
      |> RequireTokenScope.call([])

    refute conn.halted
  end

  test "passes POST requests with write token", %{write_token: token} do
    conn =
      build_conn(:post, "/api/v2/brains")
      |> assign(:current_token, token)
      |> RequireTokenScope.call([])

    refute conn.halted
  end

  test "blocks POST requests with read token", %{read_token: token} do
    conn =
      build_conn(:post, "/api/v2/brains")
      |> assign(:current_token, token)
      |> RequireTokenScope.call([])

    assert conn.halted
    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "insufficient_scope"
  end

  test "blocks PATCH and DELETE with read token", %{read_token: token} do
    for method <- [:patch, :delete] do
      conn =
        build_conn(method, "/api/v2/brains/abc")
        |> assign(:current_token, token)
        |> RequireTokenScope.call([])

      assert conn.halted, "expected #{method} to be halted"
      assert conn.status == 403
    end
  end

  test "blocks requests with no token assigned" do
    conn =
      build_conn(:post, "/api/v2/brains")
      |> RequireTokenScope.call([])

    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "missing_token"
  end
end
