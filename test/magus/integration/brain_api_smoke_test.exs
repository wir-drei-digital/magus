defmodule Magus.Integration.BrainApiSmokeTest do
  @moduledoc """
  End-to-end smoke test exercising the full Phase 1 path:
  token issuance -> plug authentication -> revoke -> 401.
  """

  use MagusWeb.ConnCase, async: true

  import Magus.Generators

  test "complete token lifecycle: issue, authenticate, revoke, 401" do
    user = generate(user())

    {:ok, %{token: token, plaintext: plaintext}} =
      Magus.Accounts.create_api_token(
        %{name: "Smoke", scope: :write, created_via: :settings},
        actor: user
      )

    # First: valid auth
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> plaintext)
      |> MagusWeb.Api.Plugs.ApiTokenAuthPlug.call([])

    refute conn.halted
    assert conn.assigns.current_user.id == user.id
    assert conn.assigns.current_token.id == token.id
    assert conn.assigns.current_token.scope == :write

    # Then: scope plug allows POST with :write
    conn2 =
      build_conn(:post, "/")
      |> assign(:current_token, conn.assigns.current_token)
      |> MagusWeb.Api.Plugs.RequireTokenScope.call([])

    refute conn2.halted

    # Then: revoke
    {:ok, _} = Magus.Accounts.revoke_api_token(token, actor: user)

    # Then: 401 on next attempt
    conn3 =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> plaintext)
      |> MagusWeb.Api.Plugs.ApiTokenAuthPlug.call([])

    assert conn3.halted
    assert conn3.status == 401
  end
end
