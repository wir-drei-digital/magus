defmodule MagusWeb.Rpc.ApiTokenControllerTest do
  @moduledoc """
  Exercises the personal-access-token controller (`/rpc/api-tokens`) used by
  the SvelteKit settings UI: create (one-time plaintext), list, and revoke,
  plus actor scoping.
  """
  use MagusWeb.ConnCase, async: true

  import Magus.Generators
  import MagusWeb.LiveViewCase, only: [log_in_user: 2]

  defp create_token(conn, user, body) do
    conn
    |> log_in_user(user)
    |> put_req_header("content-type", "application/json")
    |> post("/rpc/api-tokens", body)
    |> json_response(200)
  end

  test "create returns the token plus a one-time plaintext", %{conn: conn} do
    user = generate(user())

    assert %{"success" => true, "data" => data} =
             create_token(conn, user, %{"name" => "Laptop CLI", "scope" => "write"})

    assert data["name"] == "Laptop CLI"
    assert data["scope"] == "write"
    assert data["keyPrefix"]
    assert is_binary(data["plaintext"]) and data["plaintext"] != ""
    # The plaintext is never the stored prefix.
    refute data["plaintext"] == data["keyPrefix"]
  end

  test "an invalid scope falls back to read (whitelist, no atom injection)", %{conn: conn} do
    user = generate(user())

    assert %{"success" => true, "data" => data} =
             create_token(conn, user, %{"name" => "T", "scope" => "superuser"})

    assert data["scope"] == "read"
  end

  test "index lists only the actor's tokens", %{conn: conn} do
    user = generate(user())
    other = generate(user())

    create_token(conn, user, %{"name" => "Mine", "scope" => "read"})
    create_token(conn, other, %{"name" => "Theirs", "scope" => "read"})

    assert %{"success" => true, "data" => data} =
             conn
             |> log_in_user(user)
             |> get("/rpc/api-tokens")
             |> json_response(200)

    names = Enum.map(data, & &1["name"])
    assert "Mine" in names
    refute "Theirs" in names
  end

  test "delete revokes the actor's token", %{conn: conn} do
    user = generate(user())

    assert %{"success" => true, "data" => %{"id" => id}} =
             create_token(conn, user, %{"name" => "Revoke me", "scope" => "read"})

    assert %{"success" => true} =
             conn
             |> log_in_user(user)
             |> delete("/rpc/api-tokens/#{id}")
             |> json_response(200)

    {:ok, token} = Magus.Accounts.get_api_token(id, actor: user)
    assert token.revoked_at
  end

  test "a stranger cannot revoke another user's token", %{conn: conn} do
    owner = generate(user())
    stranger = generate(user())

    assert %{"success" => true, "data" => %{"id" => id}} =
             create_token(conn, owner, %{"name" => "Owned", "scope" => "read"})

    assert %{"success" => false} =
             conn
             |> log_in_user(stranger)
             |> delete("/rpc/api-tokens/#{id}")
             |> json_response(200)

    {:ok, token} = Magus.Accounts.get_api_token(id, actor: owner)
    refute token.revoked_at
  end

  test "unauthenticated requests are rejected", %{conn: conn} do
    conn = get(conn, "/rpc/api-tokens")
    assert conn.status in [401, 302]
  end
end
